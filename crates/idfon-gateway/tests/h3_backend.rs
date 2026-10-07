//! End-to-end proof of the H3 backend: a peer hosts an axum router, and the
//! gateway's default backend fetches a resource from it over `idfon/http3/1`.

use std::sync::Arc;
use std::time::Duration;

use axum::{http::header, routing::get, Router};
use idfon_core::transport::{IrohTransport, TransportError};
use idfon_gateway::{AccountResolver, Backend, Caller, GatewayError, IrohBackend};
use idfon_h3::serve_router;
use idfon_protocol::MessageAck;
use iroh::EndpointAddr;

/// Maps the single test account to a known peer; everything else is unknown.
struct OnePeer(EndpointAddr);

impl AccountResolver for OnePeer {
    fn resolve(&self, account: &str) -> Option<EndpointAddr> {
        (account == "acct").then(|| self.0.clone())
    }
}

#[tokio::test]
async fn fetches_a_resource_from_a_peer_over_h3() {
    let server = Arc::new(
        IrohTransport::bind_with_key(Some([11; 32]))
            .await
            .expect("server binds"),
    );
    let transport = IrohTransport::bind_with_key(Some([12; 32]))
        .await
        .expect("client binds");
    let _ = tokio::time::timeout(Duration::from_secs(5), server.endpoint().online()).await;
    let _ = tokio::time::timeout(Duration::from_secs(5), transport.endpoint().online()).await;

    let app = Router::new().route(
        "/readme",
        get(|| async {
            (
                [(header::CONTENT_TYPE, "text/plain; charset=utf-8")],
                "hello over h3",
            )
        }),
    );
    let _h3 = serve_router(&server, app);

    // Inbound H3 connections are dispatched by the transport's accept loop.
    let accept_transport = Arc::clone(&server);
    let accept = tokio::spawn(async move {
        let _ = accept_transport
            .serve(|_| async {
                Err::<MessageAck, TransportError>(TransportError::Failed(
                    "message path unused in h3 backend test".into(),
                ))
            })
            .await;
    });

    let backend =
        IrohBackend::new(&transport, OnePeer(server.endpoint().addr())).expect("backend builds");

    let resource = backend
        .fetch(&Caller::anonymous(), "acct", "/readme")
        .await
        .expect("fetches");
    assert_eq!(resource.content_type, "text/plain; charset=utf-8");
    assert_eq!(resource.body, b"hello over h3");

    // Unknown accounts never reach the peer.
    assert!(matches!(
        backend.fetch(&Caller::anonymous(), "nope", "/readme").await,
        Err(GatewayError::UnknownAccount(_))
    ));

    accept.abort();
    drop(_h3);
    server.endpoint().close().await;
    transport.endpoint().close().await;
}
