//! `idfon.net` ingress as a Cloudflare Worker.
//!
//! This is the same hybrid-gateway edge as the native `crates/idfon-edge`
//! (`docs/idfon-edge.md`), running on `workerd`: Cloudflare
//! terminates TLS and provides the wildcard origin, the Worker authenticates
//! the requester, and fetches the resource from the owner peer over
//! `idfon/http3/1` via iroh. There is no certificate file and no host.
//!
//! `iroh` runs on wasm over the relay transport (WebSocket); there is no UDP,
//! so this edge is relay-only. See `README.md` for the two workerd quirks this
//! works around (trailing-dot relay hostnames, and building `ring` on macOS).
//!
//! ```text
//! https://<ref>.idfon.net/<path>   (wildcard DNS -> this Worker)
//! https://idfon.net/<ref>/<path>   (fallback)
//! ```

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use futures_lite::StreamExt;
use idfon_core::{expiry_passed, verify_capability_ticket};
use idfon_protocol::{Capability, CapabilityTicket};
use iroh::address_lookup::{AddressLookup, EndpointData, EndpointInfo, Item, PkarrResolver};
use iroh::endpoint::presets::Minimal;
use iroh::{Endpoint, EndpointId, RelayMap, RelayMode, RelayUrl, SecretKey, TransportAddr};
use iroh_h3_client::IrohH3Client;
use n0_future::boxed::BoxStream;
use worker::*;

const ALPN: &[u8] = b"idfon/http3/1";
const TICKET_HEADER: &str = "x-idfon-ticket";
const TICKET_COOKIE: &str = "idfon_ticket";
const DEFAULT_DOMAIN: &str = "idfon.net";
const DEFAULT_CAPABILITY: &str = "resource.read";
const RATE_WINDOW_SECS: u64 = 60;

/// iroh's default relays are absolute DNS names (trailing dot). `workerd`
/// rejects trailing-dot hostnames in both `fetch` and `WebSocket`, so the edge
/// normalizes every relay URL it uses or sees.
const DEFAULT_RELAY_URLS: [&str; 4] = [
    "https://use1-1.relay.n0.iroh.link",
    "https://usw1-1.relay.n0.iroh.link",
    "https://euc1-1.relay.n0.iroh.link",
    "https://aps1-1.relay.n0.iroh.link",
];

struct Edge {
    endpoint: Endpoint,
    client: IrohH3Client,
}

static RATE: OnceLock<Mutex<HashMap<String, (u64, u32)>>> = OnceLock::new();

#[event(fetch)]
async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    console_error_panic_hook::set_once();
    let _ = tracing_wasm::try_set_as_global_default();

    let url = req.url()?;
    let path = url.path().to_owned();
    let host = url.host_str().unwrap_or_default().to_owned();
    let method = req.method();

    if path == "/healthz" {
        return Response::ok("ok");
    }
    if method != Method::Get {
        return error_response("method not allowed", 405);
    }

    let domain = string_var(&env, "EDGE_DOMAIN").unwrap_or_else(|| DEFAULT_DOMAIN.to_owned());
    let Some((reference, peer_path)) = route(&host, &path, &domain) else {
        return error_response("not found", 404);
    };
    if reference.parse::<EndpointId>().is_err() {
        // There is no directory: the ref must itself be a 64-hex endpoint id.
        return error_response("unknown ref", 404);
    }

    let auth = match authenticator(&env) {
        Ok(auth) => auth,
        Err(error) => return error_response(&error, 500),
    };
    let caller = match authenticate(&auth, req.headers(), &url) {
        Some(caller) => caller,
        None => return error_response("unauthorized", 401),
    };

    let limit = number_var(&env, "RATE_LIMIT").unwrap_or(0);
    if !rate_limit_allows(limit, &caller.subject) {
        return error_response("rate limited", 429);
    }

    // Workers are stateless and may drop the isolate's sockets between
    // requests, so dial a fresh endpoint per request and close it after. A
    // cached endpoint reuses a dead relay WebSocket and intermittently hangs.
    let edge = match build_edge(&env).await {
        Ok(edge) => edge,
        Err(error) => {
            console_log!("[idfon-edge] endpoint init failed: {error}");
            return error_response("edge unavailable", 502);
        }
    };
    let result = proxy(&edge, &reference, &peer_path, caller.ticket.as_deref()).await;
    edge.endpoint.close().await;

    let response = result?;
    console_log!(
        "[idfon-edge] {} {reference} {peer_path} caller={}",
        method.as_ref(),
        caller.subject
    );
    Ok(response)
}

// --- authentication -------------------------------------------------------

enum Auth {
    /// Shared bearer token (`Authorization: Bearer` or `?token=`).
    Token(String),
    /// A capability ticket (default `resource.read`), forwarded to the peer.
    Ticket(Capability),
}

struct Caller {
    subject: String,
    ticket: Option<String>,
}

fn authenticator(env: &Env) -> std::result::Result<Auth, String> {
    if let Some(token) = string_var(env, "EDGE_TOKEN") {
        return Ok(Auth::Token(token));
    }
    let capability =
        string_var(env, "EDGE_REQUIRE_TICKET").unwrap_or_else(|| DEFAULT_CAPABILITY.to_owned());
    Ok(Auth::Ticket(Capability::new(capability)))
}

fn authenticate(auth: &Auth, headers: &Headers, url: &Url) -> Option<Caller> {
    match auth {
        Auth::Token(expected) => {
            let presented = headers
                .get("authorization")
                .ok()
                .flatten()
                .and_then(|value| value.strip_prefix("Bearer ").map(str::to_owned))
                .or_else(|| query_param(url, "token"));
            (presented.as_deref() == Some(expected.as_str())).then(|| Caller {
                subject: "token".to_owned(),
                ticket: None,
            })
        }
        Auth::Ticket(required) => {
            let raw = ticket_from(headers, url)?;
            let ticket: CapabilityTicket = serde_json::from_str(&raw).ok()?;
            verify_capability_ticket(&ticket).ok()?;
            if !ticket.capabilities.contains(required) {
                return None;
            }
            match ticket.expires_at.as_deref() {
                Some(value) if !expiry_passed(value, now_seconds()) => {}
                _ => return None,
            }
            Some(Caller {
                subject: ticket.issuer,
                ticket: Some(raw),
            })
        }
    }
}

fn ticket_from(headers: &Headers, url: &Url) -> Option<String> {
    if let Some(value) = headers.get(TICKET_HEADER).ok().flatten() {
        return Some(value);
    }
    if let Some(cookies) = headers.get("cookie").ok().flatten() {
        if let Some(value) = cookie_value(&cookies, TICKET_COOKIE) {
            return Some(percent_decode(&value));
        }
    }
    query_param(url, "ticket").map(|value| percent_decode(&value))
}

fn query_param(url: &Url, name: &str) -> Option<String> {
    url.query_pairs()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.into_owned())
}

fn cookie_value(cookies: &str, name: &str) -> Option<String> {
    cookies.split(';').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key.trim() == name).then(|| value.trim().to_owned())
    })
}

/// Minimal percent-decoder (`%XX` and `+`), enough for a URL/cookie ticket.
fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => match (hex_nibble(bytes[i + 1]), hex_nibble(bytes[i + 2])) {
                (Some(hi), Some(lo)) => {
                    out.push((hi << 4) | lo);
                    i += 3;
                }
                _ => {
                    out.push(bytes[i]);
                    i += 1;
                }
            },
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            byte => {
                out.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

// --- routing / rate limit / edge ------------------------------------------

/// Maps the request to `(ref, path)`: `<ref>.<domain>/<path>` if the host
/// matches, else `/<ref>/<path>`. Returns `None` when there is no 64-hex ref.
fn route(host: &str, path: &str, domain: &str) -> Option<(String, String)> {
    let host = host.split(':').next().unwrap_or(host);
    if let Some(reference) = host.strip_suffix(&format!(".{domain}")) {
        if is_ref(reference) {
            return Some((reference.to_owned(), path.to_owned()));
        }
    }
    let rest = path.strip_prefix('/')?;
    let (reference, tail) = match rest.split_once('/') {
        Some((reference, tail)) => (reference, format!("/{tail}")),
        None => (rest, "/".to_owned()),
    };
    is_ref(reference).then(|| (reference.to_owned(), tail))
}

fn is_ref(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

fn iroh_uri(reference: &str, path: &str) -> String {
    format!("iroh+h3://{reference}{path}")
}

fn rate_limit_allows(limit: u32, subject: &str) -> bool {
    if limit == 0 {
        return true;
    }
    let now = now_seconds();
    let hits = RATE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut hits = hits.lock().unwrap_or_else(|error| error.into_inner());
    let entry = hits.entry(subject.to_owned()).or_insert((now, 0));
    if now.saturating_sub(entry.0) >= RATE_WINDOW_SECS {
        *entry = (now, 0);
    }
    entry.1 += 1;
    entry.1 <= limit
}

async fn proxy(
    edge: &Edge,
    reference: &str,
    path: &str,
    ticket: Option<&str>,
) -> Result<Response> {
    let mut request = edge.client.get(&iroh_uri(reference, path));
    if let Some(ticket) = ticket {
        request = request.header(TICKET_HEADER, ticket.to_owned());
    }
    let response = match request.send().await {
        Ok(response) => response,
        Err(error) => {
            console_log!("[idfon-edge] h3 {reference} {path} failed: {error}");
            return error_response("upstream unavailable", 502);
        }
    };
    let status = response.status.as_u16();
    let content_type = response
        .headers
        .get(http::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let body = match response.bytes().await {
        Ok(body) => body,
        Err(error) => {
            console_log!("[idfon-edge] h3 body {reference} {path} failed: {error}");
            return error_response("upstream read failed", 502);
        }
    };
    let headers = Headers::new();
    security_headers(&headers, content_type.as_deref());
    Ok(Response::from_bytes(body.to_vec())?
        .with_status(status)
        .with_headers(headers))
}

async fn build_edge(env: &Env) -> Result<Edge> {
    let relay_map = match string_var(env, "RELAY_URLS").filter(|value| !value.trim().is_empty()) {
        Some(list) => RelayMap::try_from_iter(list.split(',').map(str::trim))
            .map_err(|error| Error::RustError(format!("RELAY_URLS: {error}")))?,
        None => RelayMap::try_from_iter(DEFAULT_RELAY_URLS)
            .map_err(|error| Error::RustError(format!("default relays: {error}")))?,
    };
    let mut builder = Endpoint::builder(Minimal).relay_mode(RelayMode::Custom(relay_map));
    if let Some(secret) = string_var(env, "EDGE_KEY") {
        if let Some(key) = parse_secret(&secret) {
            builder = builder.secret_key(key);
        } else {
            return Err(Error::RustError("EDGE_KEY must be 64 hex characters".into()));
        }
    }
    let endpoint = builder
        .bind()
        .await
        .map_err(|error| Error::RustError(format!("iroh bind: {error}")))?;
    let resolver = PkarrResolver::n0_dns().build(endpoint.tls_config().clone());
    endpoint
        .address_lookup()
        .map_err(|error| Error::RustError(error.to_string()))?
        .add(NormalizingLookup::new(resolver));
    // Establish the home relay before the first request; wasm is relay-only.
    endpoint.online().await;
    console_log!("[idfon-edge] endpoint online: {}", endpoint.id());
    Ok(Edge {
        client: IrohH3Client::new(endpoint.clone(), ALPN.to_vec()),
        endpoint,
    })
}

fn parse_secret(hex: &str) -> Option<SecretKey> {
    let hex = hex.trim();
    let bytes = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok())
        .collect::<Option<Vec<u8>>>()?;
    let bytes: [u8; 32] = bytes.try_into().ok()?;
    Some(SecretKey::from_bytes(&bytes))
}

fn security_headers(headers: &Headers, content_type: Option<&str>) {
    if let Some(content_type) = content_type {
        let _ = headers.set("content-type", content_type);
    }
    let _ = headers.set("x-content-type-options", "nosniff");
    let _ = headers.set("referrer-policy", "no-referrer");
    let _ = headers.set("content-security-policy", "frame-ancestors 'none'");
    let _ = headers.set("cache-control", "no-store");
}

fn error_response(message: &str, status: u16) -> Result<Response> {
    Response::error(message, status)
}

/// Reads a plain var or a secret binding (both surface as a string binding).
fn string_var(env: &Env, name: &str) -> Option<String> {
    env.var(name)
        .or_else(|_| env.secret(name))
        .ok()
        .map(|value| value.to_string())
}

fn number_var(env: &Env, name: &str) -> Option<u32> {
    string_var(env, name)?.trim().parse().ok()
}

/// `std::time::SystemTime::now()` is unimplemented on `wasm32-unknown-unknown`
/// (it panics); `workerd` exposes the wall clock through `Date.now()`.
fn now_seconds() -> u64 {
    (js_sys::Date::now() / 1000.0) as u64
}

// --- relay URL normalization ----------------------------------------------

/// Wraps the pkarr resolver and strips the trailing dot from relay hostnames.
#[derive(Debug)]
struct NormalizingLookup {
    inner: PkarrResolver,
}

impl NormalizingLookup {
    fn new(inner: PkarrResolver) -> Self {
        Self { inner }
    }
}

impl AddressLookup for NormalizingLookup {
    fn resolve(
        &self,
        endpoint_id: EndpointId,
    ) -> Option<BoxStream<std::result::Result<Item, iroh::address_lookup::Error>>> {
        let stream = self.inner.resolve(endpoint_id)?;
        Some(Box::pin(stream.map(|item| item.map(normalize_item))))
    }
}

fn normalize_item(item: Item) -> Item {
    let addr = item.to_endpoint_addr();
    let addrs = addr.addrs.into_iter().map(normalize_transport);
    let mut data = EndpointData::new(addrs.collect());
    if let Some(user_data) = item.user_data() {
        data.set_user_data(Some(user_data));
    }
    Item::new(
        EndpointInfo::from_parts(item.endpoint_id(), data),
        item.provenance(),
        item.last_updated(),
    )
}

fn normalize_transport(addr: TransportAddr) -> TransportAddr {
    match addr {
        TransportAddr::Relay(url) => TransportAddr::Relay(normalize_relay(url)),
        other => other,
    }
}

/// Removes a trailing dot from the relay host (e.g. `...iroh.link./` ->
/// `...iroh.link/`). `workerd` returns `internal error` for trailing-dot hosts.
fn normalize_relay(url: RelayUrl) -> RelayUrl {
    let text = url.to_string();
    let Some((scheme, rest)) = text.split_once("://") else {
        return url;
    };
    let (host, tail) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, ""),
    };
    let host = host.strip_suffix('.').unwrap_or(host);
    format!("{scheme}://{host}{tail}").parse().unwrap_or(url)
}
