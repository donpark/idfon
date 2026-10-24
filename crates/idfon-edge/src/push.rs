//! VoIP push registry and ring fan-out (`docs/callkit-integration.md`, P2).
//!
//! Served by the gateway's [`LocalRoute`] hook on the edge's own listener, so
//! they share its TLS/origin and address like any edge resource
//! (`https://<ref>.idfon.net/_push/ring` or `https://idfon.net/<ref>/_push/ring`):
//!
//! * `POST /_push/register` `{"voip_token": "…"}` / `POST /_push/unregister` —
//!   a device claims (or releases) the ref's wake channel. Auth: a capability
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
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use http::{HeaderMap, Method, Response, StatusCode, Uri};
use http_body_util::Full;
use idfon_gateway::LocalRoute;
use idfon_protocol::CapabilityTicket;

/// Ring fan-out boundary: Apple's APNs in production, a recorder in tests.
pub trait ApnsSender: Send + Sync + 'static {
    fn send(
        &self,
        token: &str,
        topic: &str,
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
        Ok(Self {
            client,
            config,
            encoding_key,
            bearer: std::sync::Mutex::new((0, String::new())),
        })
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
}

impl ApnsSender for HttpApns {
    fn send(
        &self,
        token: &str,
        topic: &str,
        payload: serde_json::Value,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>> {
        let client = self.client.clone();
        let url = format!("{}/3/device/{}", self.config.url.trim_end_matches('/'), token);
        let topic = topic.to_owned();
        let authorization = self.bearer();
        Box::pin(async move {
            let authorization = authorization?;
            let response = client
                .post(url)
                .header("authorization", format!("bearer {authorization}"))
                .header("apns-topic", topic)
                .header("apns-push-type", "voip")
                .header("apns-priority", "10")
                .json(&payload)
                .send()
                .await
                .map_err(|error| anyhow::anyhow!("apns request: {error}"))?;
            let status = response.status();
            if !status.is_success() {
                let body = response.text().await.unwrap_or_default();
                anyhow::bail!("apns {status}: {body}");
            }
            Ok(())
        })
    }
}

/// Registered PushKit tokens per ref — `token → APNs topic` — persisted as
/// JSON so an edge restart does not drop the wake channel. The topic travels
/// with the token because tokens are per app bundle (`com.idfon.ios.voip`,
/// `com.idfon.mac.voip`): one team-level APNs key signs for both.
pub struct PushStore {
    path: PathBuf,
    tokens: Mutex<HashMap<String, HashMap<String, String>>>,
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

    pub fn register(&self, account: &str, token: &str, topic: &str) {
        let mut tokens = self.lock();
        tokens
            .entry(account.to_owned())
            .or_default()
            .insert(token.to_owned(), topic.to_owned());
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

    /// `(token, topic)` pairs registered for the ref.
    pub fn entries(&self, account: &str) -> Vec<(String, String)> {
        self.lock()
            .get(account)
            .map(|map| {
                map.iter()
                    .map(|(token, topic)| (token.clone(), topic.clone()))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, HashMap<String, String>>> {
        self.tokens.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Best-effort atomic write: a torn file must not lose the registry.
    fn persist(&self, tokens: &HashMap<String, HashMap<String, String>>) {
        let Ok(bytes) = serde_json::to_vec(tokens) else { return };
        let tmp = self.path.with_extension("tmp");
        if std::fs::write(&tmp, &bytes).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }
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
    fn matches(&self, method: &Method, path: &str) -> bool {
        method == Method::POST
            && matches!(
                path,
                "/_push/register" | "/_push/unregister" | "/_push/ring" | "/_push/cancel"
            )
    }

    fn handle(
        &self,
        account: &str,
        path: &str,
        headers: &HeaderMap,
        uri: &Uri,
        body: Bytes,
    ) -> Pin<Box<dyn Future<Output = Response<Full<Bytes>>> + Send + '_>> {
        let action = path.trim_start_matches("/_push/").to_owned();
        let account = account.to_owned();
        // The route owns auth (LocalRoute): a capability ticket issued by the
        // target ref. `?ticket=`/cookie fallbacks mirror the gateway's other
        // requesters (a WKWebView carrying the ticket).
        let ticket_raw = crate::ticket_from(headers, uri);
        Box::pin(async move {
            let Some(ticket) = ticket_raw.and_then(|raw| {
                serde_json::from_str::<CapabilityTicket>(&raw).ok()
            }) else {
                return json(StatusCode::UNAUTHORIZED, "missing or invalid ticket");
            };
            if idfon_core::verify_capability_ticket(&ticket).is_err() {
                return json(StatusCode::UNAUTHORIZED, "ticket signature invalid");
            }
            // Expired tickets are refused; a missing expiry is accepted — the
            // ring right follows the contact itself, which is long-lived.
            if ticket
                .expires_at
                .as_deref()
                .is_some_and(|at| idfon_core::expiry_passed(at, now_seconds()))
            {
                return json(StatusCode::UNAUTHORIZED, "ticket expired");
            }
            let issued_by_ref = same_ref(&ticket.issuer, &account);
            if !self.allow(&ticket.issuer) {
                return json(StatusCode::TOO_MANY_REQUESTS, "rate limited");
            }
            let Ok(value) = serde_json::from_slice::<serde_json::Value>(&body) else {
                return json(StatusCode::BAD_REQUEST, "body must be JSON");
            };
            match action.as_str() {
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
                        self.store.register(&account, token, &topic);
                    } else {
                        self.store.unregister(&account, token);
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
                    if !issued_by_ref && !same_ref(&ticket.issuer, caller_id) {
                        return json(
                            StatusCode::FORBIDDEN,
                            "ticket issued by neither this ref nor the caller",
                        );
                    }
                    // A subject-bound ticket rings only its subject's calls.
                    if let Some(subject) = &ticket.subject {
                        if subject != caller_id {
                            return json(StatusCode::FORBIDDEN, "ticket subject mismatch");
                        }
                    }
                    let Some(apns) = self.apns.as_deref() else {
                        return json(StatusCode::SERVICE_UNAVAILABLE, "push not configured");
                    };
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
                    let entries = self.store.entries(&account);
                    let mut sent = 0;
                    for (token, topic) in &entries {
                        match apns.send(token, topic, payload.clone()).await {
                            Ok(()) => sent += 1,
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
                _ => json(StatusCode::NOT_FOUND, "unknown push action"),
            }
        })
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

fn json(status: StatusCode, body: impl Into<serde_json::Value>) -> Response<Full<Bytes>> {
    // Strings are error messages; objects pass through as-is.
    let payload = match body.into() {
        serde_json::Value::String(message) => serde_json::json!({ "error": message }).to_string(),
        other => other.to_string(),
    };
    Response::builder()
        .status(status)
        .header(http::header::CONTENT_TYPE, "application/json")
        .body(Full::new(Bytes::from(payload)))
        .expect("static headers")
}

#[cfg(test)]
mod tests {
    use super::*;
    use http_body_util::BodyExt;
    use idfon_core::{generate_identity, issue_capability_ticket};

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
        let mut headers = HeaderMap::new();
        let uri: Uri = "/".parse().unwrap();
        if let Some(ticket) = ticket {
            let raw = serde_json::to_string(ticket).unwrap();
            headers.insert("x-idfon-ticket", raw.parse().unwrap());
        }
        let response = block_on(route.handle(
            account,
            path,
            &headers,
            &uri,
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
            Some(&self_ticket(&callee, Some("other-caller".to_owned()), None)),
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
