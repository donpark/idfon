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
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use http::{HeaderMap, Uri};
use idfon_core::transport::IrohTransport;
use idfon_gateway::{
    serve, AccountResolver, Authenticator, Authorizer, Caller, Config as GatewayConfig,
    GatewayHandle, IrohBackend, StaticToken, TlsConfig,
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
        if !self.allow.is_empty() && !self.allow.contains(account) {
            return None;
        }
        if let Some(addr) = self.pins.get(account) {
            return Some(addr.clone());
        }
        account.parse::<EndpointId>().ok().map(EndpointAddr::new)
    }
}

/// Requester auth for a public edge: a capability ticket whose `subject` is the
/// edge's own endpoint id. The ticket's `issuer` is the caller. `expires_at`
/// must be epoch seconds; a missing or non-numeric expiry is rejected.
pub struct CapabilityTicketAuth {
    edge_id: String,
    capability: Capability,
}

impl CapabilityTicketAuth {
    pub fn new(edge_id: impl Into<String>, capability: Capability) -> Self {
        Self {
            edge_id: edge_id.into(),
            capability,
        }
    }
}

impl Authenticator for CapabilityTicketAuth {
    fn authenticate(&self, headers: &HeaderMap, _uri: &Uri) -> Option<Caller> {
        let raw = headers.get("x-idfon-ticket")?.to_str().ok()?;
        let ticket: CapabilityTicket = serde_json::from_str(raw).ok()?;
        idfon_core::verify_capability_ticket(&ticket).ok()?;
        if ticket.subject.as_deref() != Some(self.edge_id.as_str()) {
            return None;
        }
        if !ticket.capabilities.contains(&self.capability) {
            return None;
        }
        match ticket.expires_at.as_deref() {
            Some(value) if !expiry_is_past(value) => {}
            _ => return None,
        }
        Some(Caller {
            subject: ticket.issuer,
        })
    }
}

/// Epoch-seconds expiry; anything not a future epoch second is treated as
/// expired/rejected.
fn expiry_is_past(value: &str) -> bool {
    value
        .parse::<u64>()
        .map_or(true, |seconds| seconds <= now_seconds())
}

fn now_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

/// Policy: the requester is authenticated (by [`EdgeAuth`]), resolved accounts
/// are admitted, and each caller is rate-limited to a fixed per-minute window.
/// Path/scoped policy lands with ticket-over-H3 (P3).
pub struct EdgeAuthorizer {
    window: Duration,
    limit: u32,
    hits: Mutex<HashMap<String, (Instant, u32)>>,
}

impl EdgeAuthorizer {
    /// `limit_per_minute == 0` disables rate limiting.
    pub fn new(limit_per_minute: u32) -> Self {
        Self {
            window: Duration::from_secs(60),
            limit: limit_per_minute,
            hits: Mutex::new(HashMap::new()),
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
        entry.1 <= self.limit
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
            endpoint_id.clone(),
            Capability::new(capability),
        ))),
    };
    if !bind.ip().is_loopback() && auth.is_none() {
        anyhow::bail!(
            "a non-loopback edge needs requester auth (EdgeAuth::Token or EdgeAuth::Ticket)"
        );
    }

    let backend = IrohBackend::new(&transport, EndpointRefResolver { allow, pins })?;
    let gateway = serve(
        GatewayConfig {
            bind,
            auth,
            origin_domain: domain,
            tls,
            health_path,
        },
        backend,
        EdgeAuthorizer::new(rate_limit_per_minute),
    )
    .await?;
    let addr = gateway.local_addr();
    Ok(EdgeHandle {
        addr,
        endpoint_id,
        addr_ticket,
        transport,
        gateway,
    })
}
