//! `idfon-edge` — the public-ingress half of the hybrid web architecture
//! (`docs/idfon-web-hybrid-plan.md`).
//!
//! A long-running, always-on idfon peer that terminates HTTP for a consumer
//! (a `WKWebView`, a browser, `curl`) and bridges each request to a
//! resource-owner peer over HTTP/3-over-iroh (`idfon/http3/1`). It reuses the
//! loopback gateway's mechanics ([`idfon_gateway::serve`] +
//! [`idfon_gateway::IrohBackend`]); what the edge adds is a public origin, a
//! persistent serving identity, and — in P1+ — requester authentication.
//!
//! Addressing mirrors the loopback gateway:
//!
//! ```text
//! https://<ref>.idfon.net/<path>   ->   GET <path> to the peer behind <ref>
//! https://idfon.net/<ref>/<path>   ->   same, no-wildcard fallback
//! ```
//!
//! There is no directory: `<ref>` is itself the peer's endpoint id (64 hex),
//! resolved by iroh discovery (or a pinned address). P0 admits every resolved
//! account; the bearer token is the requester boundary.

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use http::{HeaderMap, Uri};
use idfon_core::transport::IrohTransport;
use idfon_gateway::{
    serve, AccountResolver, Authenticator, Authorizer, Caller, Config as GatewayConfig,
    GatewayHandle, IrohBackend, RequestEvent, RequestObserver, StaticToken, TlsConfig,
};
use idfon_protocol::{Capability, CapabilityTicket};
use iroh::{EndpointAddr, EndpointId};

/// How long to wait for the edge endpoint to come online (relay + discovery)
/// before serving. Bounded: a host with only pinned peers still serves.
const ONLINE_TIMEOUT: Duration = Duration::from_secs(5);

/// How the edge authenticates requesters.
pub enum EdgeAuth {
    /// No requester auth. Loopback/dev only.
    Open,
    /// A shared bearer token (`Authorization: Bearer` or `?token=`).
    Token(String),
    /// A capability ticket issued to this edge's endpoint id and carrying
    /// `capability` (e.g. `web.fetch`), presented in `x-idfon-ticket`. The
    /// caller is the ticket issuer.
    Ticket { capability: String },
}

/// Edge runtime configuration.
pub struct EdgeConfig {
    /// HTTP listen address. A non-loopback bind requires non-[`EdgeAuth::Open`]
    /// auth (enforced by the gateway).
    pub bind: SocketAddr,
    /// The edge's persistent identity (ed25519 secret bytes). Stable across
    /// restarts so resource owners can grant it `resource.read`.
    pub key: [u8; 32],
    /// Endpoint ids the edge may dial. Empty = any endpoint-id ref.
    pub allow: HashSet<String>,
    /// Static ref -> address pins, checked before discovery. For tests and for
    /// operators who do not want to rely on iroh discovery.
    pub pins: HashMap<String, EndpointAddr>,
    /// Public origin base domain (`idfon.net`), enabling `<ref>.<domain>`
    /// virtual hosts. `None` accepts only loopback / `*.localhost`.
    pub domain: Option<String>,
    /// Requester authentication.
    pub auth: EdgeAuth,
    /// Serve HTTPS with this cert/key. `None` serves plain HTTP (loopback, or
    /// TLS terminated in front).
    pub tls: Option<TlsConfig>,
    /// Health-check path (default `/healthz`); `None` disables it.
    pub health_path: Option<String>,
    /// Max requests per caller per minute; `0` is unlimited.
    pub rate_limit_per_minute: u32,
}

/// A running edge. [`shutdown`](Self::shutdown) stops the HTTP listener and
/// closes the iroh endpoint.
pub struct EdgeHandle {
    /// The bound HTTP address (`0` port resolved).
    pub addr: SocketAddr,
    /// The edge's endpoint id, as resource owners see it.
    pub endpoint_id: String,
    /// The edge's serialized `EndpointAddr` ticket, for the owner's `peer add`.
    pub addr_ticket: String,
    /// Live request counters, also served at `/metrics` (after auth).
    pub metrics: Arc<EdgeMetrics>,
    transport: Arc<IrohTransport>,
    gateway: GatewayHandle,
}

impl EdgeHandle {
    pub async fn shutdown(self) {
        self.gateway.shutdown();
        self.transport.endpoint().close().await;
    }
}

/// Resolves a `<ref>` to a dialable address: a pin, else the endpoint id
/// itself via iroh discovery. No directory.
pub struct EndpointRefResolver {
    allow: HashSet<String>,
    pins: HashMap<String, EndpointAddr>,
}

impl AccountResolver for EndpointRefResolver {
    fn resolve(&self, account: &str) -> Option<EndpointAddr> {
        // Pins may name an alias; an endpoint ref may be hex (64) or z-base-32
        // (52, the DNS-label-safe form).
        if let Some(addr) = self.pins.get(account) {
            return Some(addr.clone());
        }
        let id: EndpointId = idfon_core::parse_endpoint_ref(account)?;
        let hex = id.to_string();
        if !self.allow.is_empty() && !self.allow.contains(&hex) {
            return None;
        }
        if let Some(addr) = self.pins.get(&hex) {
            return Some(addr.clone());
        }
        Some(EndpointAddr::new(id))
    }
}

/// Requester auth for a public edge: a capability ticket presented in
/// `x-idfon-ticket`, verified for signature, expiry, and the required
/// capability. The issuer becomes the caller; the raw ticket is forwarded to
/// the resource peer, which authorizes the issuer (P3 transparent edge).
pub struct CapabilityTicketAuth {
    capability: Capability,
}

impl CapabilityTicketAuth {
    pub fn new(capability: Capability) -> Self {
        Self { capability }
    }
}

impl Authenticator for CapabilityTicketAuth {
    fn authenticate(&self, headers: &HeaderMap, uri: &Uri) -> Option<Caller> {
        let raw = ticket_from(headers, uri)?;
        let ticket: CapabilityTicket = serde_json::from_str(&raw).ok()?;
        idfon_core::verify_capability_ticket(&ticket).ok()?;
        if !ticket.capabilities.contains(&self.capability) {
            return None;
        }
        match ticket.expires_at.as_deref() {
            Some(value) if !idfon_core::expiry_passed(value, now_seconds()) => {}
            _ => return None,
        }
        Some(Caller {
            subject: ticket.issuer,
            ticket: Some(raw),
        })
    }
}

const TICKET_HEADER: &str = "x-idfon-ticket";
const TICKET_COOKIE: &str = "idfon_ticket";

/// The caller's ticket: `x-idfon-ticket` header, else the `idfon_ticket`
/// cookie (how a `WKWebView` carries it), else `?ticket=`.
fn ticket_from(headers: &HeaderMap, uri: &Uri) -> Option<String> {
    if let Some(value) = headers.get(TICKET_HEADER).and_then(|v| v.to_str().ok()) {
        return Some(value.to_owned());
    }
    if let Some(value) = cookie_value(headers, TICKET_COOKIE) {
        return Some(percent_decode(&value));
    }
    query_param(uri, "ticket").map(|value| percent_decode(&value))
}

fn cookie_value(headers: &HeaderMap, name: &str) -> Option<String> {
    let cookies = headers.get(http::header::COOKIE)?.to_str().ok()?;
    cookies.split(';').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key.trim() == name).then(|| value.trim().to_owned())
    })
}

fn query_param(uri: &Uri, name: &str) -> Option<String> {
    uri.query()?.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == name).then(|| value.to_owned())
    })
}

/// Minimal percent-decoder (`%XX` and `+`), enough for a URL/cookie-encoded
/// ticket. Invalid escapes pass through.
fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                match (hex_nibble(bytes[i + 1]), hex_nibble(bytes[i + 2])) {
                    (Some(hi), Some(lo)) => {
                        out.push((hi << 4) | lo);
                        i += 3;
                    }
                    _ => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
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

fn now_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

/// Edge request counters. Doubles as the gateway's [`RequestObserver`]: every
/// served request is logged as a structured `idfon.edge.access` event and
/// counted; the counters render as Prometheus text at `/metrics` (after auth).
#[derive(Default)]
pub struct EdgeMetrics {
    total: AtomicU64,
    status_2xx: AtomicU64,
    status_3xx: AtomicU64,
    status_4xx: AtomicU64,
    status_5xx: AtomicU64,
    unauthorized: AtomicU64,
    forbidden: AtomicU64,
    rate_limited: AtomicU64,
}

/// Point-in-time view of [`EdgeMetrics`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EdgeMetricsSnapshot {
    pub total: u64,
    pub status_2xx: u64,
    pub status_3xx: u64,
    pub status_4xx: u64,
    pub status_5xx: u64,
    pub unauthorized: u64,
    pub forbidden: u64,
    pub rate_limited: u64,
}

impl EdgeMetrics {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn snapshot(&self) -> EdgeMetricsSnapshot {
        EdgeMetricsSnapshot {
            total: self.total.load(Ordering::Relaxed),
            status_2xx: self.status_2xx.load(Ordering::Relaxed),
            status_3xx: self.status_3xx.load(Ordering::Relaxed),
            status_4xx: self.status_4xx.load(Ordering::Relaxed),
            status_5xx: self.status_5xx.load(Ordering::Relaxed),
            unauthorized: self.unauthorized.load(Ordering::Relaxed),
            forbidden: self.forbidden.load(Ordering::Relaxed),
            rate_limited: self.rate_limited.load(Ordering::Relaxed),
        }
    }

    fn count_rate_limited(&self) {
        self.rate_limited.fetch_add(1, Ordering::Relaxed);
    }
}

impl RequestObserver for EdgeMetrics {
    fn observe(&self, event: &RequestEvent<'_>) {
        self.total.fetch_add(1, Ordering::Relaxed);
        match event.status.as_u16() / 100 {
            2 => self.status_2xx.fetch_add(1, Ordering::Relaxed),
            3 => self.status_3xx.fetch_add(1, Ordering::Relaxed),
            4 => self.status_4xx.fetch_add(1, Ordering::Relaxed),
            5 => self.status_5xx.fetch_add(1, Ordering::Relaxed),
            _ => 0,
        };
        if event.status == http::StatusCode::UNAUTHORIZED {
            self.unauthorized.fetch_add(1, Ordering::Relaxed);
        }
        if event.status == http::StatusCode::FORBIDDEN {
            self.forbidden.fetch_add(1, Ordering::Relaxed);
        }
        tracing::info!(
            target: "idfon.edge.access",
            method = event.method,
            host = event.host.unwrap_or("-"),
            path = event.path,
            status = event.status.as_u16(),
            latency_ms = event.latency.as_millis() as u64,
            caller = event.caller.unwrap_or("-"),
            account = event.account.unwrap_or("-"),
            "request"
        );
    }

    fn render_metrics(&self) -> Option<String> {
        let s = self.snapshot();
        Some(format!(
            "# HELP idfon_edge_requests_total Requests served by the edge.\n\
# TYPE idfon_edge_requests_total counter\n\
idfon_edge_requests_total {total}\n\
# HELP idfon_edge_responses_total Responses by status class.\n\
# TYPE idfon_edge_responses_total counter\n\
idfon_edge_responses_total{{class=\"2xx\"}} {s2}\n\
idfon_edge_responses_total{{class=\"3xx\"}} {s3}\n\
idfon_edge_responses_total{{class=\"4xx\"}} {s4}\n\
idfon_edge_responses_total{{class=\"5xx\"}} {s5}\n\
# HELP idfon_edge_unauthorized_total 401 responses.\n\
# TYPE idfon_edge_unauthorized_total counter\n\
idfon_edge_unauthorized_total {unauthorized}\n\
# HELP idfon_edge_forbidden_total 403 responses.\n\
# TYPE idfon_edge_forbidden_total counter\n\
idfon_edge_forbidden_total {forbidden}\n\
# HELP idfon_edge_rate_limited_total Requests refused by the rate limit.\n\
# TYPE idfon_edge_rate_limited_total counter\n\
idfon_edge_rate_limited_total {rate_limited}\n",
            total = s.total,
            s2 = s.status_2xx,
            s3 = s.status_3xx,
            s4 = s.status_4xx,
            s5 = s.status_5xx,
            unauthorized = s.unauthorized,
            forbidden = s.forbidden,
            rate_limited = s.rate_limited,
        ))
    }
}

/// Policy: the requester is authenticated (by [`EdgeAuth`]), resolved accounts
/// are admitted, and each caller is rate-limited to a fixed per-minute window.
/// Path/scoped policy lands with ticket-over-H3 (P3).
pub struct EdgeAuthorizer {
    window: Duration,
    limit: u32,
    hits: Mutex<HashMap<String, (Instant, u32)>>,
    metrics: Arc<EdgeMetrics>,
}

impl EdgeAuthorizer {
    /// `limit_per_minute == 0` disables rate limiting.
    pub fn new(limit_per_minute: u32, metrics: Arc<EdgeMetrics>) -> Self {
        Self {
            window: Duration::from_secs(60),
            limit: limit_per_minute,
            hits: Mutex::new(HashMap::new()),
            metrics,
        }
    }
}

impl Authorizer for EdgeAuthorizer {
    fn authorize(&self, caller: &Caller, _account: &str, _path: &str) -> bool {
        if self.limit == 0 {
            return true;
        }
        let now = Instant::now();
        let mut hits = self.hits.lock().unwrap_or_else(|error| error.into_inner());
        let entry = hits.entry(caller.subject.clone()).or_insert((now, 0));
        if now.duration_since(entry.0) >= self.window {
            *entry = (now, 0);
        }
        entry.1 += 1;
        let over = entry.1 > self.limit;
        if over {
            self.metrics.count_rate_limited();
        }
        !over
    }
}

/// Binds the edge identity and HTTP listener and serves until the handle is
/// shut down.
pub async fn run(config: EdgeConfig) -> anyhow::Result<EdgeHandle> {
    let EdgeConfig {
        bind,
        key,
        allow,
        pins,
        domain,
        auth,
        tls,
        health_path,
        rate_limit_per_minute,
    } = config;
    let transport = Arc::new(IrohTransport::bind_with_key(Some(key)).await?);
    let _ = tokio::time::timeout(ONLINE_TIMEOUT, transport.endpoint().online()).await;
    let endpoint_id = transport.endpoint().id().to_string();
    let addr_ticket = serde_json::to_string(&transport.endpoint().addr())?;

    let auth: Option<Arc<dyn Authenticator>> = match auth {
        EdgeAuth::Open => None,
        EdgeAuth::Token(token) => Some(Arc::new(StaticToken::new(token))),
        EdgeAuth::Ticket { capability } => Some(Arc::new(CapabilityTicketAuth::new(
            Capability::new(capability),
        ))),
    };
    if !bind.ip().is_loopback() && auth.is_none() {
        anyhow::bail!(
            "a non-loopback edge needs requester auth (EdgeAuth::Token or EdgeAuth::Ticket)"
        );
    }

    let backend = IrohBackend::new(&transport, EndpointRefResolver { allow, pins })?;
    let metrics = Arc::new(EdgeMetrics::new());
    let gateway = serve(
        GatewayConfig {
            bind,
            auth,
            origin_domain: domain,
            tls,
            health_path,
            metrics_path: Some("/metrics".to_owned()),
            observer: Some(metrics.clone()),
            security_headers: true,
        },
        backend,
        EdgeAuthorizer::new(rate_limit_per_minute, metrics.clone()),
    )
    .await?;
    let addr = gateway.local_addr();
    Ok(EdgeHandle {
        addr,
        endpoint_id,
        addr_ticket,
        metrics,
        transport,
        gateway,
    })
}
