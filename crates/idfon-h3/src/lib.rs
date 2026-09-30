//! HTTP/3 over an existing idfon iroh endpoint.
//!
//! This is the "host HTTP endpoints over iroh" seam. An embedder supplies an
//! [`axum::Router`]; [`serve_router`] accepts inbound connections for [`ALPN`]
//! on the daemon's own endpoint (same identity, same lifecycle as the message
//! path) and routes them through the router. [`H3Client`] issues HTTP/3
//! requests to a peer by its endpoint id.
//!
//! Both halves sit on the transport's *side-channel* ALPN plumbing: the
//! message ALPN and this one coexist, so enabling H3 does not disturb chat,
//! sync, or live-call protocols.

use std::sync::Arc;

use axum::Router;
use http::Method;
use idfon_core::transport::{IrohTransport, SideChannelGuard, TransportError};
use iroh::{
    address_lookup::memory::MemoryLookup, protocol::ProtocolHandler, EndpointAddr, EndpointId,
};
use iroh_h3_axum::IrohAxum;
use iroh_h3_client::{request::RequestBuilder, IrohH3Client};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

/// Re-exported so an embedder's router can authorize the calling peer.
pub use iroh_h3_axum::RemoteId;

/// Application protocol for HTTP/3 request/response inside idfon.
pub const ALPN: &[u8] = b"idfon/http3/1";

/// A running HTTP/3 server. Dropping it stops accepting new connections (the
/// ALPN stays registered on the endpoint).
pub struct H3Server {
    _guard: SideChannelGuard,
    task: JoinHandle<()>,
}

impl Drop for H3Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Serves an axum `router` to peers over `transport`'s existing endpoint.
///
/// Run this alongside the transport's message accept loop
/// ([`IrohTransport::serve`]): that loop dispatches inbound connections by
/// ALPN, so without it no H3 connection is ever accepted.
pub fn serve_router(transport: &Arc<IrohTransport>, router: Router) -> H3Server {
    let (tx, mut rx) = mpsc::channel(16);
    let guard = transport.add_side_channel(ALPN, tx);
    let handler = Arc::new(IrohAxum::new(router));
    let task = tokio::spawn(async move {
        while let Some(connection) = rx.recv().await {
            let handler = Arc::clone(&handler);
            // One H3 connection per task; the handler's own accept loop
            // multiplexes concurrent requests within it.
            tokio::spawn(async move {
                if let Err(error) = handler.accept(connection).await {
                    eprintln!("[idfon-h3] connection ended: {error}");
                }
            });
        }
    });
    H3Server {
        _guard: guard,
        task,
    }
}

/// An HTTP/3 client bound to `transport`'s endpoint and identity.
pub struct H3Client {
    client: IrohH3Client,
    lookup: MemoryLookup,
}

impl H3Client {
    /// Builds a client on the transport's endpoint.
    ///
    /// Inbound H3 traffic is unaffected; this only dials out. The endpoint is
    /// shared, so the peer sees the daemon's usual endpoint id.
    pub fn new(transport: &IrohTransport) -> Result<Self, TransportError> {
        let endpoint = transport.endpoint();
        let lookup = MemoryLookup::new();
        endpoint
            .address_lookup()
            .map_err(|error| TransportError::Failed(error.to_string()))?
            .add(lookup.clone());
        Ok(Self {
            client: IrohH3Client::new(endpoint.clone(), ALPN.to_vec()),
            lookup,
        })
    }

    /// Seeds a peer's addressing information (direct addresses / relay) so
    /// requests resolve without a discovery lookup.
    pub fn add_address(&self, addr: &EndpointAddr) {
        self.lookup.add_endpoint_info(addr.clone());
    }

    /// Starts an HTTP/3 `GET` to `peer` at `path`.
    pub fn get(&self, peer: &EndpointAddr, path: &str) -> RequestBuilder<IrohH3Client> {
        self.request(Method::GET, peer, path)
    }

    /// Starts an HTTP/3 `POST` to `peer` at `path`.
    pub fn post(&self, peer: &EndpointAddr, path: &str) -> RequestBuilder<IrohH3Client> {
        self.request(Method::POST, peer, path)
    }

    /// Starts an HTTP/3 request with an arbitrary method.
    pub fn request(
        &self,
        method: Method,
        peer: &EndpointAddr,
        path: &str,
    ) -> RequestBuilder<IrohH3Client> {
        self.client.request(method, uri(peer.id, path))
    }
}

/// Builds the `iroh+h3://<endpoint-id><path>` URI the client dials. The scheme
/// is nominal; the authority is what selects the peer.
pub fn uri(peer: EndpointId, path: &str) -> String {
    if path.starts_with('/') {
        format!("iroh+h3://{peer}{path}")
    } else {
        format!("iroh+h3://{peer}/{path}")
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use axum::routing::get;
    use idfon_protocol::MessageAck;

    use super::*;

    /// Two real transports, one serving an axum route, the other fetching it
    /// over HTTP/3. This is the end-to-end enabler proof.
    #[tokio::test]
    async fn router_serves_and_client_fetches_over_iroh() {
        let server = Arc::new(
            IrohTransport::bind_with_key(Some([7; 32]))
                .await
                .expect("server binds"),
        );
        let client_transport = IrohTransport::bind_with_key(Some([8; 32]))
            .await
            .expect("client binds");
        let _ = tokio::time::timeout(Duration::from_secs(5), server.endpoint().online()).await;
        let _ = tokio::time::timeout(
            Duration::from_secs(5),
            client_transport.endpoint().online(),
        )
        .await;

        let app = Router::new().route("/hello", get(|| async { "hello h3" }));
        let _h3 = serve_router(&server, app);

        // The side-channel dispatch only runs while the transport accepts.
        let accept_transport = Arc::clone(&server);
        let accept = tokio::spawn(async move {
            let _ = accept_transport
                .serve(|_| async {
                    Err::<MessageAck, TransportError>(TransportError::Failed(
                        "message path unused in h3 test".into(),
                    ))
                })
                .await;
        });

        let server_addr = server.endpoint().addr();
        let client = H3Client::new(&client_transport).expect("client builds");
        client.add_address(&server_addr);

        let response = client
            .get(&server_addr, "/hello")
            .send()
            .await
            .expect("request succeeds");
        assert_eq!(response.status, http::StatusCode::OK);
        assert_eq!(response.text().await.expect("text body"), "hello h3");

        accept.abort();
        drop(_h3);
        server.endpoint().close().await;
        client_transport.endpoint().close().await;
    }

    #[test]
    fn uri_normalizes_a_leading_slash() {
        let id: EndpointId = "0000000000000000000000000000000000000000000000000000000000000000"
            .parse()
            .unwrap();
        assert_eq!(uri(id, "hello"), uri(id, "/hello"));
        assert_eq!(uri(id, "/a/b").rsplit_once('/').unwrap().1, "b");
    }
}
