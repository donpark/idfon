//! Owner-side relay auto-enrollment (docs/relay-auth.md §6).
//!
//! When `IDFON_RELAY_ENROLL_URL` points at a relay-auth deployment, the daemon
//! keeps every local identity endpoint and every known peer device endpoint
//! admitted there, and revokes exactly the endpoints that stop existing (set
//! difference against [`Store::relay_admitted`]). Authority comes from an
//! identity key the relay lists in `IDFON_RELAY_ISSUERS`: the owner bootstrap
//! signs a single-use challenge (proof format pinned by
//! `idfon_core::relay_owner_proof_bytes` / `sign_relay_owner_proof`).
//!
//! Deliberately not here yet: caller-side grant enrollment (mint/deliver/
//! `/enroll`) — grants need persisted ticket ids plus `revoke-ticket` handling
//! or revocation becomes ineffective, so that half is a follow-up.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Result};
use ed25519_dalek::SigningKey;
use idfon_protocol::{Identity, Peer};
use tokio::sync::Notify;

use crate::Store;

/// Lease asked for on every upsert. Long enough that a laptop being closed for
/// a week is harmless; the maintenance loop tops up at half-life.
const DEFAULT_LEASE_DAYS: u64 = 30;
/// Maintenance cadence. Only needs to beat the lease half-life; mutations
/// poke the loop for immediacy.
const TICK: Duration = Duration::from_secs(6 * 60 * 60);
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);
/// Reuse a minted token until this long before its server-side expiry
/// (re-minting for every call would grow the server's token table forever).
const TOKEN_REUSE_MARGIN_MS: u64 = 5 * 60 * 1000;

static POKE: OnceLock<Arc<Notify>> = OnceLock::new();

fn notify() -> Arc<Notify> {
    POKE.get_or_init(|| Arc::new(Notify::new())).clone()
}

/// Wake the maintenance loop after a peer/identity mutation. Safe from sync
/// code and from tests with no runtime; wakes coalesce.
pub fn poke() {
    notify().notify_one();
}

/// Opt-in: `IDFON_RELAY_ENROLL_URL` is the relay-auth owner API base, e.g.
/// `https://relay.example.com:9443`. Unset = this module does nothing.
fn enroll_url() -> Option<String> {
    std::env::var("IDFON_RELAY_ENROLL_URL")
        .ok()
        .map(|value| value.trim().trim_end_matches('/').to_owned())
        .filter(|value| !value.is_empty())
}

fn lease_days() -> u64 {
    std::env::var("IDFON_RELAY_ENROLL_LEASE_DAYS")
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .filter(|days| *days > 0)
        .unwrap_or(DEFAULT_LEASE_DAYS)
}

/// The relay's admission keys are lowercase 64-hex; normalize once so a
/// malformed id never reaches the API (it would 403 "bad endpoint id" and
/// warn on every tick).
fn normalize_endpoint(value: &str) -> Option<String> {
    let lowered = value.trim().to_lowercase();
    (lowered.len() == 64 && lowered.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then_some(lowered)
}

/// Every endpoint id the daemon wants admitted: local identities' transport
/// endpoints plus each peer's primary and additional device endpoints
/// (`Peer::devices` is how a multi-device account reaches all of its devices).
/// Labels are best-effort bookkeeping for the ops view.
fn desired_endpoints(identities: &[Identity], peers: &[Peer]) -> BTreeMap<String, String> {
    let mut out: BTreeMap<String, String> = BTreeMap::new();
    let mut add = |id: &str, label: &str| {
        if let Some(id) = normalize_endpoint(id) {
            out.entry(id).or_insert_with(|| label.to_owned());
        }
    };
    for identity in identities {
        if let Some(endpoint) = identity.endpoint_id.as_deref() {
            add(endpoint, &identity.name);
        }
    }
    for peer in peers {
        if let Some(endpoint) = peer.endpoint_id.as_deref() {
            add(endpoint, &peer.name);
        }
        for device in &peer.devices {
            add(
                &device.endpoint_id,
                device.label.as_deref().unwrap_or(&peer.name),
            );
        }
    }
    out
}

/// What stops being admitted: tracked endpoints that fell out of the desired
/// set (peer removed, device removed, identity deleted — including removals
/// that arrived via state sync). Only ids this daemon tracked are touched;
/// entries created by ops or other owners are never revoked from here.
fn stale_endpoints(admitted: &BTreeSet<String>, desired: &BTreeMap<String, String>) -> Vec<String> {
    admitted
        .iter()
        .filter(|id| !desired.contains_key(*id))
        .cloned()
        .collect()
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since| since.as_millis() as u64)
        .unwrap_or_default()
}

/// The identity key + transport endpoint an owner bootstrap is bound to.
#[derive(Clone)]
struct Signer {
    /// Lowercase hex public key — must appear in the relay's
    /// `IDFON_RELAY_ISSUERS` for the bootstrap to succeed.
    identity: String,
    /// The identity's transport endpoint id (what connects to the relay).
    endpoint: String,
    key: SigningKey,
}

struct Client {
    base: String,
    lease_days: u64,
    http: reqwest::Client,
    token: tokio::sync::Mutex<Option<(String, u64)>>,
}

impl Client {
    fn new(base: String, lease_days: u64) -> Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(HTTP_TIMEOUT)
            .build()
            .map_err(|error| anyhow!("relay-auth http client: {error}"))?;
        Ok(Self {
            base,
            lease_days,
            http,
            token: tokio::sync::Mutex::new(None),
        })
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&serde_json::Value>,
        bearer: Option<&str>,
    ) -> Result<(reqwest::StatusCode, serde_json::Value)> {
        let mut request = self.http.request(method, format!("{}{path}", self.base));
        if let Some(bearer) = bearer {
            request = request.header("authorization", format!("Bearer {bearer}"));
        }
        if let Some(body) = body {
            request = request
                .header("content-type", "application/json")
                .body(serde_json::to_string(body).map_err(|error| anyhow!(error))?);
        }
        let response = request
            .send()
            .await
            .map_err(|error| anyhow!("relay-auth request failed: {error}"))?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|error| anyhow!("relay-auth response failed: {error}"))?;
        let value = serde_json::from_str(&text).unwrap_or(serde_json::Value::Null);
        Ok((status, value))
    }

    /// `POST /owner/challenge` + `POST /owner/enroll`. The relay only accepts
    /// identities it lists as issuers (403 on the challenge, no state
    /// written), which is also how a non-owner daemon discovers it is not the
    /// owner. Mints and caches the owner token.
    async fn bootstrap(&self, signer: &Signer) -> Result<String> {
        let challenge = serde_json::json!({
            "identity": signer.identity,
            "endpoint_id": signer.endpoint,
        });
        let (status, value) = self
            .call(reqwest::Method::POST, "/owner/challenge", Some(&challenge), None)
            .await?;
        if !status.is_success() {
            return Err(anyhow!("owner challenge refused: {status} {value}"));
        }
        let nonce = value
            .get("nonce")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| anyhow!("owner challenge returned no nonce: {value}"))?;
        let signature = idfon_core::sign_relay_owner_proof(
            &signer.key,
            &signer.identity,
            &signer.endpoint,
            nonce,
        );
        let enroll = serde_json::json!({
            "identity": signer.identity,
            "endpoint_id": signer.endpoint,
            "nonce": nonce,
            "signature": signature,
        });
        let (status, value) = self
            .call(reqwest::Method::POST, "/owner/enroll", Some(&enroll), None)
            .await?;
        if !status.is_success() {
            return Err(anyhow!("owner enroll refused: {status} {value}"));
        }
        let token = value
            .get("token")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| anyhow!("owner enroll returned no token: {value}"))?
            .to_owned();
        let expires = value
            .get("expires")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or_else(|| now_ms() + TOKEN_REUSE_MARGIN_MS);
        *self.token.lock().await = Some((token.clone(), expires));
        Ok(token)
    }

    async fn owner_token(&self, signer: &Signer) -> Result<String> {
        if let Some((token, expires)) = self.token.lock().await.clone() {
            if now_ms() + TOKEN_REUSE_MARGIN_MS < expires {
                return Ok(token);
            }
        }
        self.bootstrap(signer).await
    }

    /// Upsert the admission entry (extends its lease). `lease_days` keeps
    /// hand-made long leases from collapsing to the service default.
    async fn admit(&self, signer: &Signer, endpoint: &str, label: &str) -> Result<()> {
        let body = serde_json::json!({
            "endpoint_id": endpoint,
            "label": label,
            "lease_days": self.lease_days,
        });
        let mut attempt = false;
        loop {
            let token = self.owner_token(signer).await?;
            let (status, value) = self
                .call(
                    reqwest::Method::POST,
                    "/owner/entries",
                    Some(&body),
                    Some(&token),
                )
                .await?;
            if status.is_success() {
                return Ok(());
            }
            if !attempt && is_token_error(status, &value) {
                attempt = true;
                self.token.lock().await.take();
                continue;
            }
            return Err(anyhow!("admit {endpoint}: {status} {value}"));
        }
    }

    /// `true` = gone from the relay-auth state; `false` = the entry belongs to
    /// another identity (not ours to delete — stop tracking it). Errors keep
    /// the id tracked so the next tick retries.
    async fn revoke(&self, signer: &Signer, endpoint: &str) -> Result<bool> {
        let mut attempt = false;
        loop {
            let token = self.owner_token(signer).await?;
            let (status, value) = self
                .call(
                    reqwest::Method::DELETE,
                    &format!("/owner/entries/{endpoint}"),
                    None,
                    Some(&token),
                )
                .await?;
            if status.is_success() {
                return Ok(true);
            }
            if !attempt && is_token_error(status, &value) {
                attempt = true;
                self.token.lock().await.take();
                continue;
            }
            if status.as_u16() == 403
                && value
                    .get("error")
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|error| error.contains("another identity"))
            {
                return Ok(false);
            }
            return Err(anyhow!("revoke {endpoint}: {status} {value}"));
        }
    }

    /// Current leases (`GET /owner/entries`), for the top-up rule below.
    async fn leases(&self, signer: &Signer) -> Result<BTreeMap<String, u64>> {
        let mut attempt = false;
        loop {
            let token = self.owner_token(signer).await?;
            let (status, value) = self
                .call(reqwest::Method::GET, "/owner/entries", None, Some(&token))
                .await?;
            if status.is_success() {
                let mut out = BTreeMap::new();
                if let Some(entries) = value.get("entries").and_then(serde_json::Value::as_array) {
                    for entry in entries {
                        if let (Some(id), Some(expires)) = (
                            entry.get("endpoint_id").and_then(serde_json::Value::as_str),
                            entry.get("lease_expires").and_then(serde_json::Value::as_u64),
                        ) {
                            out.insert(id.to_lowercase(), expires);
                        }
                    }
                }
                return Ok(out);
            }
            if !attempt && is_token_error(status, &value) {
                attempt = true;
                self.token.lock().await.take();
                continue;
            }
            return Err(anyhow!("list entries: {status} {value}"));
        }
    }
}

fn is_token_error(status: reqwest::StatusCode, value: &serde_json::Value) -> bool {
    status.as_u16() == 401
        || (status.as_u16() == 403
            && value
                .get("error")
                .and_then(serde_json::Value::as_str)
                .is_some_and(|error| error.contains("owner token required")))
}

struct Snapshot {
    signers: Vec<Signer>,
    desired: BTreeMap<String, String>,
    admitted: BTreeSet<String>,
}

/// Snapshot what the reconcile needs and release the store lock before any
/// `.await`.
fn snapshot(store: &Arc<Mutex<Store>>) -> Snapshot {
    let state = store.lock().expect("store mutex poisoned");
    let mut signers = Vec::new();
    for identity in &state.identities {
        let (Some(endpoint), Ok(key)) = (
            identity.endpoint_id.as_deref().and_then(normalize_endpoint),
            state.identity_key(&identity.id),
        ) else {
            continue;
        };
        signers.push(Signer {
            identity: idfon_core::peer_id(&key),
            endpoint,
            key,
        });
    }
    Snapshot {
        desired: desired_endpoints(&state.identities, &state.peers),
        admitted: state
            .relay_admitted
            .iter()
            .filter_map(|id| normalize_endpoint(id))
            .collect(),
        signers,
    }
}

fn persist_admitted(store: &Arc<Mutex<Store>>, admitted: &BTreeSet<String>) -> Result<()> {
    let mut state = store.lock().expect("store mutex poisoned");
    state.relay_admitted = admitted.iter().cloned().collect();
    let data_dir = state.data_dir.clone();
    state
        .save(&data_dir)
        .map_err(|error| anyhow!("save relay_admitted: {error}"))
}

async fn reconcile(
    client: &Client,
    store: &Arc<Mutex<Store>>,
    owner: &mut Option<Signer>,
) -> Result<()> {
    let snapshot = snapshot(store);
    if snapshot.signers.is_empty() {
        return Ok(());
    }
    // Owner authority: the first identity whose key the relay trusts as an
    // issuer. Remembered across ticks (the token cache lives in the client).
    if owner.is_none() {
        for signer in &snapshot.signers {
            match client.owner_token(signer).await {
                Ok(_) => {
                    *owner = Some(signer.clone());
                    break;
                }
                Err(error) => {
                    tracing::debug!(target: "idfon.daemon", identity = %signer.identity, error = %error, "not a relay issuer");
                }
            }
        }
    }
    let Some(signer) = owner.clone() else {
        tracing::info!(target: "idfon.daemon", "relay enrollment skipped: no local identity key is listed in IDFON_RELAY_ISSUERS");
        return Ok(());
    };

    // Top-up rule: skip an upsert while the server-side lease is still long.
    // Keeps hand-made multi-year entries (infra agents) from collapsing to our
    // lease, and turns the loop into "extend before it lapses".
    let leases = client.leases(&signer).await.unwrap_or_default();
    let top_up_below = now_ms() + client.lease_days * 24 * 60 * 60 * 1000 / 2;

    let mut admitted = snapshot.admitted.clone();
    for (endpoint, label) in &snapshot.desired {
        // /owner/enroll already keeps the bootstrapping endpoint alive with an
        // owner-role entry; upserting it here would downgrade it to caller.
        if *endpoint == signer.endpoint {
            admitted.insert(endpoint.clone());
            continue;
        }
        if leases
            .get(endpoint)
            .is_some_and(|expires| *expires > top_up_below)
        {
            admitted.insert(endpoint.clone());
            continue;
        }
        match client.admit(&signer, endpoint, label).await {
            Ok(()) => {
                admitted.insert(endpoint.clone());
            }
            Err(error) => {
                tracing::warn!(target: "idfon.daemon", endpoint = %endpoint, error = %error, "relay admission upsert failed");
            }
        }
    }

    for endpoint in stale_endpoints(&admitted, &snapshot.desired) {
        match client.revoke(&signer, &endpoint).await {
            Ok(true) => {
                admitted.remove(&endpoint);
            }
            Ok(false) => {
                tracing::info!(target: "idfon.daemon", endpoint = %endpoint, "relay entry owned by another identity; leaving it");
                admitted.remove(&endpoint);
            }
            Err(error) => {
                tracing::warn!(target: "idfon.daemon", endpoint = %endpoint, error = %error, "relay revocation failed; will retry");
            }
        }
    }

    if admitted != snapshot.admitted {
        persist_admitted(store, &admitted)?;
    }
    Ok(())
}

/// Spawn the maintenance loop. No-op unless `IDFON_RELAY_ENROLL_URL` is set.
pub fn spawn(store: Arc<Mutex<Store>>) {
    let Some(base) = enroll_url() else {
        return;
    };
    tokio::spawn(async move {
        let client = match Client::new(base, lease_days()) {
            Ok(client) => client,
            Err(error) => {
                tracing::warn!(target: "idfon.daemon", error = %error, "relay enrollment disabled: http client");
                return;
            }
        };
        let notify = notify();
        let mut interval = tokio::time::interval(TICK);
        let mut owner: Option<Signer> = None;
        loop {
            if let Err(error) = reconcile(&client, &store, &mut owner).await {
                tracing::warn!(target: "idfon.daemon", error = %error, "relay enrollment reconcile failed");
            }
            tokio::select! {
                _ = interval.tick() => {}
                _ = notify.notified() => {}
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    use ed25519_dalek::{Signature, Verifier};

    fn identity(id: &str, name: &str, endpoint: &str) -> Identity {
        Identity {
            id: id.into(),
            name: name.into(),
            endpoint_id: Some(endpoint.into()),
            public_key: None,
            active: true,
        }
    }

    fn peer(id: &str, name: &str, endpoint: &str, devices: Vec<(&str, Option<&str>)>) -> Peer {
        Peer {
            id: id.into(),
            identity: "default".into(),
            name: name.into(),
            endpoint_id: Some(endpoint.into()),
            endpoint_addr: None,
            devices: devices
                .into_iter()
                .map(|(endpoint, label)| idfon_protocol::PeerDevice {
                    endpoint_id: endpoint.into(),
                    endpoint_addr: None,
                    label: label.map(Into::into),
                    device_class: None,
                    capabilities: Vec::new(),
                })
                .collect(),
            aliases: Vec::new(),
            call_mode: Default::default(),
            pinned: false,
            instant_call: false,
        }
    }

    #[test]
    fn desired_endpoints_covers_account_devices() {
        let identities = vec![
            identity(
                "default",
                "Personal",
                "aa11111111111111111111111111111111111111111111111111111111111111",
            ),
            // Malformed ids never reach the API.
            identity("broken", "Broken", "not-an-endpoint"),
        ];
        let peers = vec![peer(
            "acct",
            "iPhone",
            "bb22222222222222222222222222222222222222222222222222222222222222",
            vec![(
                "cc33333333333333333333333333333333333333333333333333333333333333",
                Some("iPad"),
            )],
        )];
        let desired = desired_endpoints(&identities, &peers);
        let ids: Vec<&str> = desired.keys().map(String::as_str).collect();
        assert_eq!(
            ids,
            vec![
                "aa11111111111111111111111111111111111111111111111111111111111111",
                "bb22222222222222222222222222222222222222222222222222222222222222",
                "cc33333333333333333333333333333333333333333333333333333333333333",
            ]
        );
        assert_eq!(
            desired
                ["cc33333333333333333333333333333333333333333333333333333333333333"],
            "iPad"
        );
    }

    #[test]
    fn stale_endpoints_are_the_set_difference() {
        let keep = "aa".to_owned() + &"11".repeat(31);
        let gone = "bb".to_owned() + &"22".repeat(31); // e.g. synced peer removal
        let admitted: BTreeSet<String> = [keep.clone(), gone.clone()].into_iter().collect();
        let desired = BTreeMap::from([(keep.clone(), "phone".to_owned())]);
        assert_eq!(stale_endpoints(&admitted, &desired), vec![gone]);
    }

    /// Scripted relay-auth: captures (method, path, body) and answers from a
    /// canned queue. reqwest may pipeline several requests over one
    /// connection, so the loop keeps reading until EOF.
    fn serve(script: Vec<(u16, String)>) -> (String, Arc<Mutex<Vec<(String, String, String)>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let base = format!("http://{}", listener.local_addr().expect("addr"));
        let captured: Arc<Mutex<Vec<(String, String, String)>>> = Arc::new(Mutex::new(Vec::new()));
        let script = Arc::new(Mutex::new(script));
        let sink = Arc::clone(&captured);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let script = Arc::clone(&script);
                let sink = Arc::clone(&sink);
                std::thread::spawn(move || loop {
                    let mut head = Vec::new();
                    let mut byte = [0u8; 1];
                    while !head.ends_with(b"\r\n\r\n") {
                        if stream.read(&mut byte).unwrap_or(0) == 0 {
                            return;
                        }
                        head.push(byte[0]);
                    }
                    let head = String::from_utf8_lossy(&head).to_string();
                    let mut lines = head.lines();
                    let request_line = lines.next().unwrap_or_default().to_owned();
                    let mut parts = request_line.split_whitespace();
                    let method = parts.next().unwrap_or_default().to_owned();
                    let path = parts.next().unwrap_or_default().to_owned();
                    let length: usize = lines
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .map(|value| value.trim().parse().unwrap_or(0))
                        })
                        .unwrap_or(0);
                    let mut body = vec![0u8; length];
                    let mut read = 0;
                    while read < length {
                        match stream.read(&mut body[read..]) {
                            Ok(0) | Err(_) => return,
                            Ok(n) => read += n,
                        }
                    }
                    sink.lock()
                        .expect("captured")
                        .push((method, path, String::from_utf8_lossy(&body).into_owned()));
                    let (status, payload) = script
                        .lock()
                        .expect("script")
                        .pop()
                        .unwrap_or((404, r#"{"error":"exhausted"}"#.into()));
                    let response = format!(
                        "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: keep-alive\r\n\r\n{payload}",
                        payload.len()
                    );
                    if stream.write_all(response.as_bytes()).is_err() {
                        return;
                    }
                });
            }
        });
        (base, captured)
    }

    fn signer() -> Signer {
        let key = idfon_core::decode_signing_key(&"07".repeat(32)).expect("fixed key");
        let endpoint = "11".repeat(32);
        Signer {
            identity: idfon_core::peer_id(&key),
            endpoint: endpoint.clone(),
            key,
        }
    }

    #[tokio::test]
    async fn client_wire_shapes_match_the_service() {
        let far = now_ms() + 60 * 60 * 1000;
        let (base, captured) = serve(vec![
            // The queue is LIFO: last queued is served first.
            (200, format!(r#"{{"revoked":"22{}"}}"#, "22".repeat(31))),
            (200, r#"{"endpoint_id":"x","lease_expires":1}"#.to_owned()),
            (
                200,
                format!(r#"{{"token":"tok.abc","expires":{far},"endpoint_id":"x"}}"#),
            ),
            (200, r#"{"nonce":"00112233445566778899aabbccddeeff","expires":0}"#.to_owned()),
        ]);
        let client = Client::new(base, 30).expect("client");
        let signer = signer();

        // Owner bootstrap: the proof over the wire verifies against the
        // identity key — the exact cross-language contract.
        client.bootstrap(&signer).await.expect("bootstrap");
        {
            let captured = captured.lock().expect("captured");
            assert_eq!(captured[0], (
                "POST".into(),
                "/owner/challenge".into(),
                format!(r#"{{"endpoint_id":"{}","identity":"{}"}}"#, signer.endpoint, signer.identity),
            ));
            let enroll: serde_json::Value = serde_json::from_str(&captured[1].2).expect("json");
            assert_eq!(enroll["nonce"], "00112233445566778899aabbccddeeff");
            assert_eq!(enroll["identity"], signer.identity);
            assert_eq!(enroll["endpoint_id"], signer.endpoint);
            let proof = idfon_core::relay_owner_proof_bytes(
                &signer.identity,
                &signer.endpoint,
                "00112233445566778899aabbccddeeff",
            );
            let raw = hex_bytes(enroll["signature"].as_str().expect("signature"));
            let signature =
                Signature::from_bytes(<&[u8; 64]>::try_from(raw.as_slice()).expect("64 bytes"));
            signer
                .key
                .verifying_key()
                .verify(&proof, &signature)
                .expect("proof verifies");
        }

        // Admit: bearer + lease_days; then revoke: DELETE on the entry path.
        let endpoint = "22".repeat(32);
        client.admit(&signer, &endpoint, "phone").await.expect("admit");
        assert!(client.revoke(&signer, &endpoint).await.expect("revoke"));
        {
            let captured = captured.lock().expect("captured");
            assert_eq!(captured.len(), 4, "token is cached; no second bootstrap");
            assert_eq!(captured[2].0, "POST");
            assert_eq!(captured[2].1, "/owner/entries");
            let body: serde_json::Value = serde_json::from_str(&captured[2].2).expect("json");
            assert_eq!(body["endpoint_id"], endpoint);
            assert_eq!(body["label"], "phone");
            assert_eq!(body["lease_days"], 30);
            assert_eq!(captured[3], (
                "DELETE".into(),
                format!("/owner/entries/{endpoint}"),
                String::new(),
            ));
        }
    }

    #[tokio::test]
    async fn admit_retries_once_on_a_rejected_token() {
        // Request order: challenge, enroll, entries (403 token), challenge,
        // enroll, entries (200). The queue is LIFO.
        let (base, captured) = serve(vec![
            (200, r#"{"endpoint_id":"x","lease_expires":1}"#.to_owned()),
            (
                200,
                format!(r#"{{"token":"tok.new","expires":{},"endpoint_id":"x"}}"#, now_ms() + 60_000),
            ),
            (200, r#"{"nonce":"aabb","expires":0}"#.to_owned()),
            (403, r#"{"error":"owner token required"}"#.to_owned()),
            (
                200,
                format!(r#"{{"token":"tok.old","expires":{},"endpoint_id":"x"}}"#, now_ms() + 60_000),
            ),
            (200, r#"{"nonce":"0011","expires":0}"#.to_owned()),
        ]);
        let client = Client::new(base, 30).expect("client");
        let signer = signer();
        client
            .admit(&signer, &"33".repeat(32), "x")
            .await
            .expect("admit after retry");
        let captured = captured.lock().expect("captured");
        let paths: Vec<&str> = captured.iter().map(|(_, p, _)| p.as_str()).collect();
        assert_eq!(
            paths,
            vec![
                "/owner/challenge",
                "/owner/enroll",
                "/owner/entries",
                "/owner/challenge",
                "/owner/enroll",
                "/owner/entries",
            ]
        );
    }

    fn hex_bytes(value: &str) -> Vec<u8> {
        (0..value.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&value[i..i + 2], 16).expect("hex"))
            .collect()
    }
}
