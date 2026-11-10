//! VoIP push registry and ring fan-out (`docs/callkit-integration.md`, P2).
//!
//! Served by the gateway's [`LocalRoute`] hook on the edge's own listener, so
//! they share its TLS/origin and address like any edge resource
//! (`https://<ref>.idfon.net/_push/ring` or `https://idfon.net/<ref>/_push/ring`):
//!
//! * `POST /_push/register` `{"voip_token": "…", "topic": "…", "env":
//!   "sandbox"|"production"}` / `POST /_push/unregister` — a device claims
//!   (or releases) the ref's wake channel. `env` is the environment the app's
//!   own entitlements put its token in; optional, so an older app keeps
//!   working (absent = the sender learns it by trying the configured host and
//!   flipping once). Auth: a capability
//!   ticket **issued by the ref** (self-issued through the daemon's
//!   `capability.ticket` RPC), so only the identity's holder can claim it.
//! * `POST /_push/ring` `{"call_uuid", "caller_id", "has_video"}` /
//!   `POST /_push/cancel` `{"call_uuid"}` — ring the ref's registered devices
//!   (or retract the ring). Auth: a capability ticket issued by the ref (the
//!   caller's contact ticket — being a contact is the right to ring) **or by
//!   the caller** (a self-issued identity statement: accountable and
//!   rate-limited, so a plain paired peer can ring before a contact ticket
//!   exists). When the ticket has a `subject`, it must equal `caller_id`.
//!
//! Ring/cancel fan out one VoIP push (`apns-push-type: voip`) per registered
//! token. The payload carries **identifiers only** (`call_uuid`, `caller_id`,
//! `has_video`, `cancel`) — the device resolves display names from its own
//! peer store, keeping peer names out of APNs logs.

use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use http::{HeaderMap, Method, Response, StatusCode, Uri};
use hyper::body::Incoming;
use idfon_gateway::{LocalRoute, ResponseBody};
use idfon_core::CapabilityTicket;

/// VoIP pushes are call-time events: expire them shortly after instead of
/// storing for a later, useless wake (late pushes cause ghost rings).
const PUSH_EXPIRATION_SECS: u64 = 30;

/// Ring fan-out boundary: Apple's APNs in production, a recorder in tests.
pub trait ApnsSender: Send + Sync + 'static {
    /// `env` is the environment the registering app declared for its token;
    /// `None` (an older app) falls back to learning it by trying.
    fn send(
        &self,
        token: &str,
        topic: &str,
        env: Option<TokenEnv>,
        payload: serde_json::Value,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>>;
}

/// APNs HTTP/2 connection settings (`.p8` auth key + topic).
#[derive(Debug, Clone)]
pub struct ApnsConfig {
    pub key_file: PathBuf,
    pub key_id: String,
    pub team_id: String,
    /// Default VoIP topic (`com.idfon.ios.voip`). Tokens may register under
    /// another app's topic (e.g. `com.idfon.mac.voip`) — one team-level key
    /// signs for every app, and the topic travels with each token.
    pub topic: String,
    /// `https://api.push.apple.com` or `https://api.sandbox.push.apple.com`.
    pub url: String,
}

/// Real APNs sender: signed JWT (ES256, `kid` = key id), cached — HTTP/2.
///
/// Per-token environment: a dev-signed build's PushKit token only delivers
/// via the sandbox host, a TestFlight/App Store build's only via production
/// (`BadEnvironmentKeyInToken` otherwise). Mixed fleets are the normal case
/// (external TestFlight testers next to `pnpm ios device` installs), so each
/// token *learns* its environment: try the configured host, flip to the
/// counterpart on the env refusal, remember the verdict in memory (a restart
/// re-learns per token at the cost of one refused send).
pub struct HttpApns {
    client: reqwest::Client,
    config: ApnsConfig,
    encoding_key: jsonwebtoken::EncodingKey,
    /// Cached provider JWT `(iat, token)`. Apple rejects providers that mint
    /// a new token more than ~once per 20 min (429
    /// `TooManyProviderTokenUpdates`) while the token stays valid ~1 h —
    /// sign once, reuse, refresh at 50 min. Signing per request throttles
    /// the whole provider into silence (observed 2026-10-23).
    bearer: std::sync::Mutex<(u64, String)>,
    /// `(production host, sandbox host)` — see `plan_hosts`.
    hosts: (String, String),
    default_env: TokenEnv,
    /// Learned per-token environments (in-memory, see the type doc).
    envs: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, TokenEnv>>>,
}

/// The APNs environment a device token belongs to.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TokenEnv {
    Production,
    Sandbox,
}

impl TokenEnv {
    fn other(self) -> Self {
        match self {
            Self::Production => Self::Sandbox,
            Self::Sandbox => Self::Production,
        }
    }
}

impl HttpApns {
    pub fn new(config: ApnsConfig) -> anyhow::Result<Self> {
        let pem = std::fs::read(&config.key_file)
            .map_err(|error| anyhow::anyhow!("reading APNs key {}: {error}", config.key_file.display()))?;
        let encoding_key = jsonwebtoken::EncodingKey::from_ec_pem(&pem)
            .map_err(|error| anyhow::anyhow!("parsing APNs key: {error}"))?;
        // TLS ALPN negotiates HTTP/2 with APNs; no forced version needed.
        let client = reqwest::Client::builder()
            .build()
            .map_err(|error| anyhow::anyhow!("building APNs client: {error}"))?;
        let (hosts, default_env) = Self::plan_hosts(&config.url);
        Ok(Self {
            client,
            config,
            encoding_key,
            bearer: std::sync::Mutex::new((0, String::new())),
            hosts,
            default_env,
            envs: std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
        })
    }

    /// `(production host, sandbox host)` + the configured URL's own env. The
    /// counterpart of a standard host is the other standard host; a custom
    /// host has no counterpart (no fallback).
    fn plan_hosts(url: &str) -> ((String, String), TokenEnv) {
        if url.contains("api.sandbox.push.apple.com") {
            (
                ("https://api.push.apple.com".to_owned(), url.trim_end_matches('/').to_owned()),
                TokenEnv::Sandbox,
            )
        } else if url.contains("api.push.apple.com") {
            (
                (url.trim_end_matches('/').to_owned(), "https://api.sandbox.push.apple.com".to_owned()),
                TokenEnv::Production,
            )
        } else {
            let own = url.trim_end_matches('/').to_owned();
            ((own.clone(), own), TokenEnv::Production)
        }
    }

    /// The refusal body that means "this token belongs to the other
    /// environment" (observed: `BadEnvironmentKeyInToken`; Apple docs also
    /// spell it `BadEnvironmentKeyIdInToken` — match both).
    fn env_error(error: &anyhow::Error) -> bool {
        let text = error.to_string();
        text.contains("BadEnvironmentKeyInToken") || text.contains("BadEnvironmentKeyIdInToken")
    }

    /// A refusal that means "this token is no longer installed" (410):
    /// prune it.
    fn unregistered_error(error: &anyhow::Error) -> bool {
        let text = error.to_string();
        text.contains("Unregistered") || text.contains("ExpiredToken")
    }

    /// `BadDeviceToken` is ambiguous (documented env mismatch vs dead
    /// token): try the counterpart host once, prune only when both refuse.
    fn bad_token_error(error: &anyhow::Error) -> bool {
        error.to_string().contains("BadDeviceToken")
    }

    /// Wraps a refusal that means the registration is dead — the fan-out
    /// prunes the token when it sees this.
    fn stale_token(error: &anyhow::Error) -> anyhow::Error {
        anyhow::anyhow!("stale apns token: {error}")
    }

    /// Whether a send error marks the token dead (see [`Self::stale_token`]).
    pub(crate) fn is_stale_token(error: &anyhow::Error) -> bool {
        error.to_string().starts_with("stale apns token")
    }

    fn bearer(&self) -> anyhow::Result<String> {
        #[derive(serde::Serialize)]
        struct Claims {
            iss: String,
            iat: u64,
        }
        let mut cached = self.bearer.lock().unwrap_or_else(|error| error.into_inner());
        let now = now_seconds();
        if !cached.1.is_empty() && now.saturating_sub(cached.0) < 50 * 60 {
            return Ok(cached.1.clone());
        }
        let mut header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::ES256);
        header.kid = Some(self.config.key_id.clone());
        let claims = Claims {
            iss: self.config.team_id.clone(),
            iat: now,
        };
        let token = jsonwebtoken::encode(&header, &claims, &self.encoding_key)
            .map_err(|error| anyhow::anyhow!("signing APNs token: {error}"))?;
        *cached = (now, token.clone());
        Ok(token)
    }

    async fn post(
        client: &reqwest::Client,
        authorization: &str,
        host: &str,
        token: &str,
        topic: &str,
        payload: &serde_json::Value,
    ) -> anyhow::Result<()> {
        let url = format!("{}/3/device/{}", host, token);
        let response = client
            .post(url)
            .header("authorization", format!("bearer {authorization}"))
            .header("apns-topic", topic)
            .header("apns-push-type", "voip")
            .header("apns-priority", "10")
            .header(
                "apns-expiration",
                (now_seconds() + PUSH_EXPIRATION_SECS).to_string(),
            )
            .json(payload)
            .send()
            .await
            .map_err(|error| anyhow::anyhow!("apns request: {error}"))?;
        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("apns [{host}] {status}: {body}");
        }
        Ok(())
    }
}

impl ApnsSender for HttpApns {
    fn send(
        &self,
        token: &str,
        topic: &str,
        declared: Option<TokenEnv>,
        payload: serde_json::Value,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>> {
        let client = self.client.clone();
        let hosts = self.hosts.clone();
        let envs = std::sync::Arc::clone(&self.envs);
        let learned = self
            .envs
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .get(token)
            .copied();
        // What the app said at registration beats what the edge learned: a
        // reinstall changes the entitlement, and a stale learned verdict
        // costs a refused send on the next ring.
        let env = declared.or(learned).unwrap_or(self.default_env);
        let token = token.to_owned();
        let topic = topic.to_owned();
        let authorization = self.bearer();
        Box::pin(async move {
            let authorization = authorization?;
            let host = if env == TokenEnv::Production { &hosts.0 } else { &hosts.1 };
            let refused =
                match Self::post(&client, &authorization, host, &token, &topic, &payload).await {
                    Ok(()) => return Ok(()),
                    Err(error) => error,
                };
            if Self::unregistered_error(&refused) {
                return Err(Self::stale_token(&refused));
            }
            // Wrong environment (env refusal) or an ambiguous
            // BadDeviceToken: the counterpart may be the right host. If it
            // also refuses with a token error, the token is dead in both —
            // prune it at the fan-out.
            if Self::env_error(&refused) || Self::bad_token_error(&refused) {
                let other = env.other();
                let other_host = if other == TokenEnv::Production { &hosts.0 } else { &hosts.1 };
                tracing::warn!(
                    target: "idfon.edge.push",
                    from = host,
                    to = other_host,
                    "token refused by its environment; trying the counterpart"
                );
                return match Self::post(&client, &authorization, other_host, &token, &topic, &payload)
                    .await
                {
                    Ok(()) => {
                        envs
                            .lock()
                            .unwrap_or_else(|error| error.into_inner())
                            .insert(token, other);
                        Ok(())
                    }
                    Err(error) => {
                        envs
                            .lock()
                            .unwrap_or_else(|error| error.into_inner())
                            .remove(&token);
                        if Self::unregistered_error(&error) || Self::bad_token_error(&error) {
                            Err(Self::stale_token(&error))
                        } else {
                            Err(error)
                        }
                    }
                };
            }
            Err(refused)
        })
    }
}

/// One registered device: its APNs topic and, when the app declares it, the
/// environment it minted its token in (C24: a dev-signed build's PushKit
/// token only delivers through the sandbox host). `env: None` means an app
/// that predates the field — the sender learns the environment by trying.
#[derive(Clone, Debug, serde::Serialize)]
pub struct TokenRecord {
    pub topic: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub env: Option<TokenEnv>,
}

impl<'de> serde::Deserialize<'de> for TokenRecord {
    // Pre-`env` edges wrote `token → "topic"`; read both shapes so an
    // upgrade does not drop the wake registry.
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(serde::Deserialize)]
        #[serde(untagged)]
        enum Stored {
            Legacy(String),
            Record {
                topic: String,
                #[serde(default)]
                env: Option<TokenEnv>,
            },
        }
        Ok(match Stored::deserialize(deserializer)? {
            Stored::Legacy(topic) => TokenRecord { topic, env: None },
            Stored::Record { topic, env } => TokenRecord { topic, env },
        })
    }
}

/// Registered PushKit tokens per ref — `token → [`TokenRecord`]` — persisted as
/// JSON so an edge restart does not drop the wake channel. The topic travels
/// with the token because tokens are per app bundle (`com.idfon.ios.voip`,
/// `com.idfon.mac.voip`): one team-level APNs key signs for both.
pub struct PushStore {
    path: PathBuf,
    tokens: Mutex<HashMap<String, HashMap<String, TokenRecord>>>,
}

impl PushStore {
    pub fn load(path: PathBuf) -> Self {
        let tokens = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self {
            path,
            tokens: Mutex::new(tokens),
        }
    }

    pub fn register(&self, account: &str, token: &str, topic: &str, env: Option<TokenEnv>) {
        let mut tokens = self.lock();
        tokens.entry(account.to_owned()).or_default().insert(
            token.to_owned(),
            TokenRecord {
                topic: topic.to_owned(),
                env,
            },
        );
        self.persist(&tokens);
    }

    pub fn unregister(&self, account: &str, token: &str) {
        let mut tokens = self.lock();
        if let Some(map) = tokens.get_mut(account) {
            map.remove(token);
            if map.is_empty() {
                tokens.remove(account);
            }
            self.persist(&tokens);
        }
    }

    /// `(token, record)` pairs registered for the ref.
    pub fn entries(&self, account: &str) -> Vec<(String, TokenRecord)> {
        self.lock()
            .get(account)
            .map(|map| {
                map.iter()
                    .map(|(token, record)| (token.clone(), record.clone()))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, HashMap<String, TokenRecord>>> {
        self.tokens.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Best-effort atomic write: a torn file must not lose the registry.
    fn persist(&self, tokens: &HashMap<String, HashMap<String, TokenRecord>>) {
        let Ok(bytes) = serde_json::to_vec(tokens) else { return };
        let tmp = self.path.with_extension("tmp");
        if std::fs::write(&tmp, &bytes).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }
}

/// A ring's invite kept briefly so a push-woken callee can pull it when the
/// iroh envelope has not landed yet (SIP push-bucket shape,
/// docs/callkit-brittleness.md P1). In-memory and short-lived: the iroh
/// invite path remains the durable one.
const OFFER_TTL: Duration = Duration::from_secs(300);

struct StoredOffer {
    account: String,
    caller_id: String,
    invite: String,
    expires: Instant,
}

/// The edge's `/_push/*` routes. `apns: None` answers 503 (push unconfigured)
/// instead of silently accepting rings nobody receives.
pub struct PushRoutes {
    store: Arc<PushStore>,
    apns: Option<Arc<dyn ApnsSender>>,
    /// Topic for registrations that carry none.
    default_topic: String,
    /// Per-issuer fixed window: ringing is a wake channel, keep it cheap to abuse.
    limits: Mutex<HashMap<String, (Instant, u32)>>,
    per_minute: u32,
    /// Pending invites by call uuid (see [`OFFER_TTL`]).
    offers: Mutex<HashMap<String, StoredOffer>>,
}

impl PushRoutes {
    pub fn new(
        store: Arc<PushStore>,
        apns: Option<Arc<dyn ApnsSender>>,
        default_topic: String,
    ) -> Self {
        Self {
            store,
            apns,
            default_topic,
            limits: Mutex::new(HashMap::new()),
            per_minute: 30,
            offers: Mutex::new(HashMap::new()),
        }
    }

    fn allow(&self, issuer: &str) -> bool {
        let now = Instant::now();
        let mut limits = self.limits.lock().unwrap_or_else(|error| error.into_inner());
        let entry = limits.entry(issuer.to_owned()).or_insert((now, 0));
        if now.duration_since(entry.0).as_secs() >= 60 {
            *entry = (now, 0);
        }
        entry.1 += 1;
        entry.1 <= self.per_minute
    }
}

impl LocalRoute for PushRoutes {
    fn matches(&self, method: &Method, _account: &str, path: &str) -> bool {
        method == Method::POST
            && matches!(
                path,
                "/_push/register" | "/_push/unregister" | "/_push/ring" | "/_push/cancel"
                    | "/_push/pull" | "/_push/health"
            )
    }

    fn handle(
        &self,
        _method: &Method,
        account: &str,
        path: &str,
        headers: &HeaderMap,
        _uri: &Uri,
        body: Incoming,
    ) -> Pin<Box<dyn Future<Output = Response<ResponseBody>> + Send + '_>> {
        let action = path.trim_start_matches("/_push/").to_owned();
        let account = account.to_owned();
        // The route owns auth (LocalRoute): a capability ticket issued by the
        // target ref. The header/host-only cookie are shared with WebView auth;
        // URL-ticket fallback is deliberately disabled.
        let ticket_raw = crate::ticket_from(headers);
        Box::pin(async move {
            let body = match idfon_gateway::collect_limited(body, idfon_gateway::MAX_RESOURCE_BYTES)
                .await
            {
                Ok(body) => body,
                Err(status) => return json(status, "body too large"),
            };
            self.handle_body(&account, &action, ticket_raw, body).await
        })
    }
}

impl PushRoutes {
    /// Route body after body collection, shared by the gateway path and the
    /// tests (which have no `Incoming` to hand over).
    async fn handle_body(
        &self,
        account: &str,
        action: &str,
        ticket_raw: Option<String>,
        body: Bytes,
    ) -> Response<ResponseBody> {
            let Some(ticket) = ticket_raw.and_then(|raw| CapabilityTicket::decode(raw.trim()).ok())
            else {
                return json(StatusCode::UNAUTHORIZED, "missing or invalid ticket");
            };
            // Expired tickets are refused; a missing expiry is accepted — the
            // ring right follows the contact itself, which is long-lived.
            if ticket.expires_at().is_some_and(|at| at <= now_seconds()) {
                return json(StatusCode::UNAUTHORIZED, "ticket expired");
            }
            let issued_by_ref = same_ref(&ticket.issuer(), account);
            if !self.allow(&ticket.issuer()) {
                return json(StatusCode::TOO_MANY_REQUESTS, "rate limited");
            }
            let Ok(value) = serde_json::from_slice::<serde_json::Value>(&body) else {
                return json(StatusCode::BAD_REQUEST, "body must be JSON");
            };
            match action {
                "register" | "unregister" => {
                    // Only the identity's holder may claim its wake channel.
                    if !issued_by_ref {
                        return json(StatusCode::FORBIDDEN, "ticket not issued by this ref");
                    }
                    let Some(token) = value.get("voip_token").and_then(|v| v.as_str()) else {
                        return json(StatusCode::BAD_REQUEST, "voip_token required");
                    };
                    if token.is_empty() || token.len() > 512 {
                        return json(StatusCode::BAD_REQUEST, "voip_token invalid");
                    }
                    if action == "register" {
                        // The topic is the registering app's VoIP topic
                        // (`<bundle-id>.voip`); tokens are per app bundle.
                        let topic = match value.get("topic") {
                            None | Some(serde_json::Value::Null) => self.default_topic.clone(),
                            Some(value) => match value.as_str() {
                                Some(topic) if !topic.is_empty() && topic.len() <= 200 => {
                                    topic.to_owned()
                                }
                                _ => return json(StatusCode::BAD_REQUEST, "topic invalid"),
                            },
                        };
                        let env = match value.get("env") {
                            None | Some(serde_json::Value::Null) => None,
                            Some(value) => match serde_json::from_value::<TokenEnv>(value.clone()) {
                                Ok(env) => Some(env),
                                Err(_) => return json(StatusCode::BAD_REQUEST, "env invalid"),
                            },
                        };
                        self.store.register(account, token, &topic, env);
                    } else {
                        self.store.unregister(account, token);
                    }
                    json(StatusCode::OK, "{}")
                }
                "ring" | "cancel" => {
                    let Some(call_uuid) = value.get("call_uuid").and_then(|v| v.as_str()) else {
                        return json(StatusCode::BAD_REQUEST, "call_uuid required");
                    };
                    if call_uuid.is_empty() || call_uuid.len() > 256 {
                        return json(StatusCode::BAD_REQUEST, "call_uuid invalid");
                    }
                    let caller_id = value
                        .get("caller_id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    if action == "ring" && caller_id.is_empty() {
                        return json(StatusCode::BAD_REQUEST, "caller_id required");
                    }
                    // Being a contact is the right to ring (the caller holds
                    // the ref's contact ticket); a caller self-issued statement
                    // is accepted too — identified and rate-limited, so a plain
                    // paired peer can ring before a contact ticket exists.
                    if !issued_by_ref && !same_ref(&ticket.issuer(), caller_id) {
                        return json(
                            StatusCode::FORBIDDEN,
                            "ticket issued by neither this ref nor the caller",
                        );
                    }
                    // A subject-bound ticket rings only its subject's calls.
                    if let Some(subject) = &ticket.subject() {
                        if subject != caller_id {
                            return json(StatusCode::FORBIDDEN, "ticket subject mismatch");
                        }
                    }
                    let Some(apns) = self.apns.as_deref() else {
                        return json(StatusCode::SERVICE_UNAVAILABLE, "push not configured");
                    };
                    // Keep the invite briefly so a woken callee whose iroh
                    // envelope has not landed can pull it (`/_push/pull`).
                    {
                        let mut offers =
                            self.offers.lock().unwrap_or_else(|error| error.into_inner());
                        offers.retain(|_, offer| offer.expires > Instant::now());
                        if action == "ring" {
                            if let Some(invite) = value.get("invite").and_then(|v| v.as_str()) {
                                if invite.len() > 16 * 1024 {
                                    return json(StatusCode::BAD_REQUEST, "invite too large");
                                }
                                if !invite.is_empty() {
                                    offers.insert(
                                        call_uuid.to_owned(),
                                        StoredOffer {
                                            account: account.to_owned(),
                                            caller_id: caller_id.to_owned(),
                                            invite: invite.to_owned(),
                                            expires: Instant::now() + OFFER_TTL,
                                        },
                                    );
                                }
                            }
                        } else {
                            offers.remove(call_uuid);
                        }
                    }
                    // Identifiers only: the device resolves the display name.
                    let payload = if action == "ring" {
                        serde_json::json!({
                            "call_uuid": call_uuid,
                            "caller_id": caller_id,
                            "has_video": value.get("has_video").and_then(|v| v.as_bool()).unwrap_or(false),
                        })
                    } else {
                        serde_json::json!({ "call_uuid": call_uuid, "cancel": true })
                    };
                    let entries = self.store.entries(account);
                    let mut sent = 0;
                    for (token, record) in &entries {
                        match apns.send(token, &record.topic, record.env, payload.clone()).await {
                            Ok(()) => sent += 1,
                            Err(error) if HttpApns::is_stale_token(&error) => {
                                // 410 or both hosts refuse: the registration
                                // is dead. Prune it so a reinstall's fresh
                                // token is not shadowed by corpses.
                                tracing::warn!(
                                    target: "idfon.edge.push",
                                    %error,
                                    "pruning stale token"
                                );
                                self.store.unregister(account, token);
                            }
                            Err(error) => {
                                tracing::warn!(target: "idfon.edge.push", %error, "apns send failed")
                            }
                        }
                    }
                    json(
                        StatusCode::OK,
                        serde_json::json!({ "ok": true, "rung": sent }),
                    )
                }
                "health" => {
                    // Tier-1 diagnostics (`docs/mcp-control.md`): the ref's
                    // holder may see its wake-channel health. Counts only —
                    // no token ever leaves this response.
                    if !issued_by_ref {
                        return json(StatusCode::FORBIDDEN, "ticket not issued by this ref");
                    }
                    let entries = self.store.entries(account);
                    let topics: std::collections::BTreeSet<&str> =
                        entries.iter().map(|(_, record)| record.topic.as_str()).collect();
                    let offers = self.offers.lock().unwrap_or_else(|error| error.into_inner());
                    let pending = offers
                        .values()
                        .filter(|offer| offer.account == account && offer.expires > Instant::now())
                        .count();
                    json(
                        StatusCode::OK,
                        serde_json::json!({
                            "registered_tokens": entries.len(),
                            "topics": topics,
                            "pending_offers": pending,
                            "apns_configured": self.apns.is_some(),
                        }),
                    )
                }
                "pull" => {
                    // The ref's holder fetches its own pending invite
                    // (self-issued ticket, the registration rule).
                    if !issued_by_ref {
                        return json(StatusCode::FORBIDDEN, "ticket not issued by this ref");
                    }
                    let Some(call_uuid) = value.get("call_uuid").and_then(|v| v.as_str()) else {
                        return json(StatusCode::BAD_REQUEST, "call_uuid required");
                    };
                    let offers = self.offers.lock().unwrap_or_else(|error| error.into_inner());
                    match offers.get(call_uuid) {
                        Some(offer)
                            if offer.account == account && offer.expires > Instant::now() =>
                        {
                            json(
                                StatusCode::OK,
                                serde_json::json!({
                                    "caller_id": offer.caller_id,
                                    "invite": offer.invite,
                                }),
                            )
                        }
                        _ => json(StatusCode::NOT_FOUND, "no pending offer"),
                    }
                }
                _ => json(StatusCode::NOT_FOUND, "unknown push action"),
            }
    }
}

/// Refs may be presented as hex (64) or z-base-32 (52); compare identities,
/// not spellings.
fn same_ref(a: &str, b: &str) -> bool {
    match (idfon_core::parse_endpoint_ref(a), idfon_core::parse_endpoint_ref(b)) {
        (Some(a), Some(b)) => a == b,
        _ => a == b,
    }
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

fn json(status: StatusCode, body: impl Into<serde_json::Value>) -> Response<ResponseBody> {
    // Strings are error messages; objects pass through as-is.
    let payload = match body.into() {
        serde_json::Value::String(message) => serde_json::json!({ "error": message }).to_string(),
        other => other.to_string(),
    };
    Response::builder()
        .status(status)
        .header(http::header::CONTENT_TYPE, "application/json")
        .body(idfon_gateway::bytes_body(payload))
        .expect("static headers")
}

#[cfg(test)]
mod tests {
    use super::*;
    use http_body_util::BodyExt;
    use idfon_core::{generate_identity, issue_capability_ticket};

    #[test]
    fn apns_env_fallback_recognizes_the_environment_refusal() {
        let refused: anyhow::Error =
            anyhow::anyhow!("apns 403 Forbidden: {{\"reason\":\"BadEnvironmentKeyInToken\"}}");
        assert!(HttpApns::env_error(&refused));
        let other: anyhow::Error =
            anyhow::anyhow!("apns 400 Forbidden: {{\"reason\":\"BadDeviceToken\"}}");
        assert!(!HttpApns::env_error(&other));

        let (hosts, env) = HttpApns::plan_hosts("https://api.push.apple.com");
        assert_eq!(env, TokenEnv::Production);
        assert_eq!(hosts.1, "https://api.sandbox.push.apple.com");
        let (hosts, env) = HttpApns::plan_hosts("https://api.sandbox.push.apple.com");
        assert_eq!(env, TokenEnv::Sandbox);
        assert_eq!(hosts.0, "https://api.push.apple.com");
        assert_eq!(TokenEnv::Production.other(), TokenEnv::Sandbox);
    }

    struct StaleApns;

    impl ApnsSender for StaleApns {
        fn send(
            &self,
            _token: &str,
            _topic: &str,
            _env: Option<TokenEnv>,
            _payload: serde_json::Value,
        ) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>> {
            Box::pin(async {
                Err(HttpApns::stale_token(&anyhow::anyhow!(
                    "apns 410: {{\"reason\":\"Unregistered\"}}"
                )))
            })
        }
    }

    #[test]
    fn stale_tokens_are_pruned_from_the_registry() {
        let refused = anyhow::anyhow!("apns 410: {{\"reason\":\"Unregistered\"}}");
        assert!(HttpApns::unregistered_error(&refused));
        assert!(HttpApns::unregistered_error(&anyhow::anyhow!(
            "apns 410: {{\"reason\":\"ExpiredToken\"}}"
        )));
        assert!(HttpApns::is_stale_token(&HttpApns::stale_token(&refused)));
        assert!(!HttpApns::is_stale_token(&refused));

        let key = generate_identity();
        let account = idfon_core::peer_id(&key);
        let (store, routes) = routes(Some(Arc::new(StaleApns)));
        let ticket = self_ticket(&key, None, Some("2999-01-01T00:00:00Z".to_owned()));

        let (status, _) = post(
            &routes,
            &account,
            "/_push/register",
            Some(&ticket),
            serde_json::json!({ "voip_token": "token-dead" }),
        );
        assert_eq!(status, StatusCode::OK);
        assert_eq!(store.entries(&account).len(), 1);

        let (status, body) = post(
            &routes,
            &account,
            "/_push/ring",
            Some(&ticket),
            serde_json::json!({
                "call_uuid": "11111111-1111-1111-1111-111111111111",
                "caller_id": "caller"
            }),
        );
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["rung"], 0);
        assert!(
            store.entries(&account).is_empty(),
            "a dead token must be pruned so a reinstall is not shadowed by it"
        );
    }

    #[test]
    fn registration_carries_the_apns_environment() {
        let key = generate_identity();
        let account = idfon_core::peer_id(&key);
        let (store, routes) = routes(Some(MockApns::new()));
        let ticket = self_ticket(&key, None, Some("2999-01-01T00:00:00Z".to_owned()));

        let (status, _) = post(
            &routes,
            &account,
            "/_push/register",
            Some(&ticket),
            serde_json::json!({ "voip_token": "token-sandbox", "env": "sandbox" }),
        );
        assert_eq!(status, StatusCode::OK);
        let entries = store.entries(&account);
        let record = entries.iter().find(|(token, _)| token == "token-sandbox").unwrap();
        assert_eq!(record.1.env, Some(TokenEnv::Sandbox));

        let (status, _) = post(
            &routes,
            &account,
            "/_push/register",
            Some(&ticket),
            serde_json::json!({ "voip_token": "token-bad", "env": "staging" }),
        );
        assert_eq!(status, StatusCode::BAD_REQUEST);

        // A pre-`env` edge wrote `token → "topic"`; an upgrade must still read it.
        let path = std::env::temp_dir().join(format!(
            "idfon-push-legacy-{}.json",
            std::process::id()
        ));
        std::fs::write(&path, r#"{"acct":{"legacy":"com.idfon.ios.voip"}}"#).unwrap();
        let legacy = PushStore::load(path.clone());
        let entries = legacy.entries("acct");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].1.topic, "com.idfon.ios.voip");
        assert_eq!(entries[0].1.env, None);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn jwt_signing_has_a_crypto_provider() {
        // Regression 2026-11-10: with no crypto feature enabled, jsonwebtoken
        // 11 panics at request time ("Could not automatically determine the
        // process-level CryptoProvider") — every ring/cancel died mid-request
        // while register kept working. Throwaway P-256 key, test-only.
        let pem = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZgYML+FLO4dLJSTQ\nye5a8jXgbgPkfbx7+dee1As/po6hRANCAASRY301eE6MRlKInb210n/Y8hDOvVoi\nXoaF6Ro+7sHLXL/7UOCGPDjRE8wNfXls8iOy82YaEigXHgfRKy6qyCl6\n-----END PRIVATE KEY-----";
        let key = jsonwebtoken::EncodingKey::from_ec_pem(pem.as_bytes()).expect("test key parses");
        let mut header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::ES256);
        header.kid = Some("TESTKEY000".to_owned());
        jsonwebtoken::encode(
            &header,
            &serde_json::json!({"iss": "test", "iat": 1}),
            &key,
        )
        .expect("JWT signing must have a crypto provider");
    }

    #[test]
    fn health_reports_counts_and_never_tokens() {
        let key = generate_identity();
        let account = idfon_core::peer_id(&key);
        let other_key = generate_identity();
        let (_store, routes) = routes(Some(MockApns::new()));
        let ticket = self_ticket(&key, None, Some("2999-01-01T00:00:00Z".to_owned()));

        let (status, _) = post(
            &routes,
            &account,
            "/_push/register",
            Some(&ticket),
            serde_json::json!({ "voip_token": "token-secret", "topic": "com.idfon.ios.voip" }),
        );
        assert_eq!(status, StatusCode::OK);

        let (status, body) = post(
            &routes,
            &account,
            "/_push/health",
            Some(&ticket),
            serde_json::json!({}),
        );
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["registered_tokens"], 1);
        assert_eq!(body["apns_configured"], true);
        assert!(!body.to_string().contains("token-secret"), "health never leaks tokens");

        let foreign = self_ticket(&other_key, None, Some("2999-01-01T00:00:00Z".to_owned()));
        let (status, _) = post(
            &routes,
            &account,
            "/_push/health",
            Some(&foreign),
            serde_json::json!({}),
        );
        assert_eq!(status, StatusCode::FORBIDDEN);
    }

    #[test]
    fn pending_offer_survives_for_pull_and_dies_with_the_cancel() {
        let key = generate_identity();
        let account = idfon_core::peer_id(&key);
        let other_key = generate_identity();
        let (_store, routes) = routes(Some(MockApns::new()));
        let ticket = self_ticket(&key, None, Some("2999-01-01T00:00:00Z".to_owned()));
        let call = "22222222-2222-2222-2222-222222222222";

        let (status, _) = post(
            &routes,
            &account,
            "/_push/ring",
            Some(&ticket),
            serde_json::json!({
                "call_uuid": call,
                "caller_id": "caller",
                "invite": "IDFON-LIVE/1\naction=start\nticket=t1"
            }),
        );
        assert_eq!(status, StatusCode::OK);

        // The callee pulls its own pending invite...
        let (status, body) = post(
            &routes,
            &account,
            "/_push/pull",
            Some(&ticket),
            serde_json::json!({ "call_uuid": call }),
        );
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["invite"], "IDFON-LIVE/1\naction=start\nticket=t1");

        // ...but nobody else's.
        let foreign = self_ticket(&other_key, None, Some("2999-01-01T00:00:00Z".to_owned()));
        let (status, _) = post(
            &routes,
            &account,
            "/_push/pull",
            Some(&foreign),
            serde_json::json!({ "call_uuid": call }),
        );
        assert_eq!(status, StatusCode::FORBIDDEN);

        // A cancel takes the offer with it.
        let (status, _) = post(
            &routes,
            &account,
            "/_push/cancel",
            Some(&ticket),
            serde_json::json!({ "call_uuid": call }),
        );
        assert_eq!(status, StatusCode::OK);
        let (status, _) = post(
            &routes,
            &account,
            "/_push/pull",
            Some(&ticket),
            serde_json::json!({ "call_uuid": call }),
        );
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    struct MockApns {
        sent: Mutex<Vec<(String, String, serde_json::Value)>>,
    }

    impl MockApns {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                sent: Mutex::new(Vec::new()),
            })
        }
    }

    impl ApnsSender for MockApns {
        fn send(
            &self,
            token: &str,
            topic: &str,
            _env: Option<TokenEnv>,
            payload: serde_json::Value,
        ) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>> {
            self.sent
                .lock()
                .unwrap()
                .push((token.to_owned(), topic.to_owned(), payload));
            Box::pin(async { Ok(()) })
        }
    }

    fn routes(apns: Option<Arc<dyn ApnsSender>>) -> (Arc<PushStore>, PushRoutes) {
        let store = Arc::new(PushStore::load(std::env::temp_dir().join(format!(
            "idfon-push-test-{}.json",
            std::process::id()
        ))));
        (
            store.clone(),
            PushRoutes::new(store, apns, "com.idfon.ios.voip".to_owned()),
        )
    }

    fn post(
        route: &PushRoutes,
        account: &str,
        path: &str,
        ticket: Option<&CapabilityTicket>,
        body: serde_json::Value,
    ) -> (StatusCode, serde_json::Value) {
        let ticket_raw = ticket.map(|ticket| ticket.token());
        let response = block_on(route.handle_body(
            account,
            path.trim_start_matches("/_push/"),
            ticket_raw,
            Bytes::from(body.to_string()),
        ));
        let status = response.status();
        let bytes = block_on(async move { response.into_body().collect().await.unwrap().to_bytes() });
        (status, serde_json::from_slice(&bytes).unwrap_or_default())
    }

    fn block_on<F: Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(future)
    }

    fn self_ticket(
        key: &ed25519_dalek::SigningKey,
        subject: Option<String>,
        expires_at: Option<String>,
    ) -> CapabilityTicket {
        issue_capability_ticket(
            key,
            subject,
            vec![idfon_protocol::Capability::new("message.send")],
            expires_at,
            "test-ticket",
        )
        .expect("mints")
    }

    #[test]
    fn register_and_ring_fan_out_identifiers_only() {
        let key = generate_identity();
        let account = idfon_core::peer_id(&key);
        let apns = MockApns::new();
        let (_store, routes) = routes(Some(apns.clone()));
        let ticket = self_ticket(&key, None, Some("2999-01-01T00:00:00Z".to_owned()));

        for (token, topic) in [
            ("token-ios", Option::<&str>::None),
            ("token-mac", Some("com.idfon.mac.voip")),
        ] {
            let mut body = serde_json::json!({ "voip_token": token });
            if let Some(topic) = topic {
                body["topic"] = topic.into();
            }
            let (status, _) = post(&routes, &account, "/_push/register", Some(&ticket), body);
            assert_eq!(status, StatusCode::OK);
        }
        let (status, body) = post(
            &routes,
            &account,
            "/_push/ring",
            Some(&ticket),
            serde_json::json!({ "call_uuid": "uuid-1", "caller_id": "caller", "has_video": true }),
        );
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["rung"], 2);

        let mut sent = apns.sent.lock().unwrap().clone();
        sent.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[0].2["call_uuid"], "uuid-1");
        assert_eq!(sent[0].2["caller_id"], "caller");
        assert_eq!(sent[0].2["has_video"], true);
        // Identifiers only: no display names in the APNs payload.
        assert!(sent[0].2.get("caller_name").is_none());
        // Each token is pushed with its own app's topic: one key, many bundles.
        assert_eq!(sent[0].1, "com.idfon.ios.voip");
        assert_eq!(sent[1].1, "com.idfon.mac.voip");
    }

    #[test]
    fn ring_rejects_unrelated_tickets() {
        let callee = generate_identity();
        let stranger = generate_identity();
        let account = idfon_core::peer_id(&callee);
        let apns = MockApns::new();
        let (_store, routes) = routes(Some(apns.clone()));
        let body = serde_json::json!({ "call_uuid": "uuid-1", "caller_id": "caller" });

        // No ticket at all.
        let (status, _) = post(&routes, &account, "/_push/ring", None, body.clone());
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        // A valid ticket, but issued by someone else.
        let (status, _) = post(
            &routes,
            &account,
            "/_push/ring",
            Some(&self_ticket(&stranger, None, None)),
            body.clone(),
        );
        assert_eq!(status, StatusCode::FORBIDDEN);
        // A subject-bound ticket must match the ring's caller.
        let (status, _) = post(
            &routes,
            &account,
            "/_push/ring",
            Some(&self_ticket(&callee, Some(idfon_core::peer_id(&stranger)), None)),
            body,
        );
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert!(apns.sent.lock().unwrap().is_empty());
    }

    #[test]
    fn expired_tickets_are_refused() {
        let key = generate_identity();
        let account = idfon_core::peer_id(&key);
        let (_store, routes) = routes(None);
        let expired = self_ticket(&key, None, Some("2000-01-01T00:00:00Z".to_owned()));
        let (status, _) = post(
            &routes,
            &account,
            "/_push/ring",
            Some(&expired),
            serde_json::json!({ "call_uuid": "uuid-1", "caller_id": "caller" }),
        );
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn cancel_retracts_and_unregister_stops_delivery() {
        let key = generate_identity();
        let account = idfon_core::peer_id(&key);
        let apns = MockApns::new();
        let (_store, routes) = routes(Some(apns.clone()));
        let ticket = self_ticket(&key, None, None);

        let (status, _) = post(
            &routes,
            &account,
            "/_push/register",
            Some(&ticket),
            serde_json::json!({ "voip_token": "token-a" }),
        );
        assert_eq!(status, StatusCode::OK);
        let (status, _) = post(
            &routes,
            &account,
            "/_push/cancel",
            Some(&ticket),
            serde_json::json!({ "call_uuid": "uuid-1" }),
        );
        assert_eq!(status, StatusCode::OK);
        let sent = apns.sent.lock().unwrap().clone();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].2["cancel"], true);

        let (status, _) = post(
            &routes,
            &account,
            "/_push/unregister",
            Some(&ticket),
            serde_json::json!({ "voip_token": "token-a" }),
        );
        assert_eq!(status, StatusCode::OK);
        let (status, body) = post(
            &routes,
            &account,
            "/_push/ring",
            Some(&ticket),
            serde_json::json!({ "call_uuid": "uuid-2", "caller_id": "caller" }),
        );
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["rung"], 0);
        assert_eq!(apns.sent.lock().unwrap().len(), 1);
    }

    #[test]
    fn ring_accepts_a_caller_self_issued_statement() {
        let callee = generate_identity();
        let caller = generate_identity();
        let account = idfon_core::peer_id(&callee);
        let caller_id = idfon_core::peer_id(&caller);
        let apns = MockApns::new();
        let (_store, routes) = routes(Some(apns));
        // Registration stays strict: the caller cannot claim the ref's channel.
        let (status, _) = post(
            &routes,
            &account,
            "/_push/register",
            Some(&self_ticket(&caller, None, None)),
            serde_json::json!({ "voip_token": "token-a" }),
        );
        assert_eq!(status, StatusCode::FORBIDDEN);
        // But it can ring, identified by its own signed statement.
        let (status, _) = post(
            &routes,
            &account,
            "/_push/ring",
            Some(&self_ticket(&caller, None, None)),
            serde_json::json!({ "call_uuid": "uuid-1", "caller_id": caller_id }),
        );
        assert_eq!(status, StatusCode::OK);
    }

    #[test]
    fn unconfigured_push_answers_503() {
        let key = generate_identity();
        let account = idfon_core::peer_id(&key);
        let (_store, routes) = routes(None);
        let (status, _) = post(
            &routes,
            &account,
            "/_push/ring",
            Some(&self_ticket(&key, None, None)),
            serde_json::json!({ "call_uuid": "uuid-1", "caller_id": "caller" }),
        );
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    }
}
