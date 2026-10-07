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
use std::sync::Arc;
use std::time::Duration;

use http::{HeaderMap, Uri};
use idfon_core::transport::IrohTransport;
use idfon_gateway::{
    serve, AccountResolver, Authenticator, Authorizer, Caller, Config as GatewayConfig,
    GatewayHandle, IrohBackend, StaticToken,
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
}

/// A running edge. [`shutdown`](Self::shutdown) stops the HTTP listener and
/// closes the iroh endpoint.
pub struct EdgeHandle {
    /// The bound HTTP address (`0` port resolved).
    pub addr: SocketAddr,
    /// The edge's endpoint id, as resource owners see it.
    pub endpoint_id: String,
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

/// P0/P1 policy: the requester is authenticated and resolved accounts are
/// admitted. Path/scoped policy lands with ticket-over-H3 (P3).
pub struct EdgeAuthorizer;

impl Authorizer for EdgeAuthorizer {
    fn authorize(&self, _caller: &Caller, _account: &str, _path: &str) -> bool {
        true
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
    } = config;
    let transport = Arc::new(IrohTransport::bind_with_key(Some(key)).await?);
    let _ = tokio::time::timeout(ONLINE_TIMEOUT, transport.endpoint().online()).await;
    let endpoint_id = transport.endpoint().id().to_string();

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
        },
        backend,
        EdgeAuthorizer,
    )
    .await?;
    let addr = gateway.local_addr();
    Ok(EdgeHandle {
        addr,
        endpoint_id,
        transport,
        gateway,
    })
}
