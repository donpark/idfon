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

use idfon_core::transport::IrohTransport;
use idfon_gateway::{
    serve, AccountResolver, Authorizer, Config as GatewayConfig, GatewayHandle, IrohBackend,
};
use iroh::{EndpointAddr, EndpointId};

/// How long to wait for the edge endpoint to come online (relay + discovery)
/// before serving. Bounded: a host with only pinned peers still serves.
const ONLINE_TIMEOUT: Duration = Duration::from_secs(5);

/// Edge runtime configuration.
pub struct EdgeConfig {
    /// HTTP listen address. A non-loopback bind requires `token` (enforced by
    /// the gateway).
    pub bind: SocketAddr,
    /// Requester bearer token; `None` only for a loopback bind.
    pub token: Option<String>,
    /// The edge's persistent identity (ed25519 secret bytes). Stable across
    /// restarts so resource owners can grant it `resource.read`.
    pub key: [u8; 32],
    /// Endpoint ids the edge may dial. Empty = any endpoint-id ref.
    pub allow: HashSet<String>,
    /// Static ref -> address pins, checked before discovery. For tests and for
    /// operators who do not want to rely on iroh discovery.
    pub pins: HashMap<String, EndpointAddr>,
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

/// P0 policy: the bearer token is the requester boundary, so every resolved
/// account is admitted. Path/scoped policy lands with ticket-over-H3 (P3).
pub struct EdgeAuthorizer;

impl Authorizer for EdgeAuthorizer {
    fn authorize(&self, _account: &str, _path: &str) -> bool {
        true
    }
}

/// Binds the edge identity and HTTP listener and serves until the handle is
/// shut down.
pub async fn run(config: EdgeConfig) -> anyhow::Result<EdgeHandle> {
    let EdgeConfig {
        bind,
        token,
        key,
        allow,
        pins,
    } = config;
    let transport = Arc::new(IrohTransport::bind_with_key(Some(key)).await?);
    let _ = tokio::time::timeout(ONLINE_TIMEOUT, transport.endpoint().online()).await;
    let endpoint_id = transport.endpoint().id().to_string();
    let backend = IrohBackend::new(&transport, EndpointRefResolver { allow, pins })?;
    let gateway = serve(GatewayConfig { bind, token }, backend, EdgeAuthorizer).await?;
    let addr = gateway.local_addr();
    Ok(EdgeHandle {
        addr,
        endpoint_id,
        transport,
        gateway,
    })
}
