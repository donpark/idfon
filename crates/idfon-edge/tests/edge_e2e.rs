//! End-to-end proof of the edge: a peer serves one route over H3, and the edge
//! bridges an HTTP request to it. Also asserts the requester token and the
//! endpoint-id allow-list.

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use idfon_core::transport::{IrohTransport, TransportError};
use idfon_edge::{run, EdgeConfig};
use idfon_h3::{serve_router, RemoteId};
use idfon_protocol::MessageAck;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Reports the endpoint id the peer saw, so the test can prove the edge (not
/// the requester) is the caller at the P2P layer.
async fn readme(RemoteId(remote): RemoteId) -> Response {
    (axum::http::StatusCode::OK, format!("remote={remote}")).into_response()
}

async fn http_get(addr: SocketAddr, path: &str, token: Option<&str>) -> (u16, String) {
    let mut stream = tokio::net::TcpStream::connect(addr)
        .await
        .expect("connect edge");
    let mut request = format!("GET {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n");
    if let Some(token) = token {
        request.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    request.push_str("\r\n");
    stream
        .write_all(request.as_bytes())
        .await
        .expect("write request");

    let mut buf = Vec::new();
    let _ = tokio::time::timeout(Duration::from_secs(10), stream.read_to_end(&mut buf)).await;
    let text = String::from_utf8_lossy(&buf);
    let mut parts = text.splitn(2, "\r\n\r\n");
    let head = parts.next().unwrap_or_default();
    let body = parts.next().unwrap_or_default().to_owned();
    let status = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse().ok())
        .unwrap_or(0);
    (status, body)
}

#[tokio::test]
async fn edge_bridges_and_gates() {
    let server = Arc::new(
        IrohTransport::bind_with_key(Some([21; 32]))
            .await
            .expect("peer binds"),
    );
    let _h3 = serve_router(&server, Router::new().route("/fs/readme", get(readme)));
    // Inbound H3 connections are dispatched by the transport accept loop.
    let accept_transport = Arc::clone(&server);
    let accept = tokio::spawn(async move {
        let _ = accept_transport
            .serve(|_| async {
                Err::<MessageAck, TransportError>(TransportError::Failed(
                    "message path unused in edge e2e".into(),
                ))
            })
            .await;
    });
    let peer_id = server.endpoint().id().to_string();

    let handle = run(EdgeConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        token: Some("s3cret".into()),
        key: [22; 32],
        allow: HashSet::from([peer_id.clone()]),
        pins: HashMap::from([(peer_id.clone(), server.endpoint().addr())]),
    })
    .await
    .expect("edge runs");

    let path = format!("/{peer_id}/fs/readme");

    let (status, _) = http_get(handle.addr, &path, None).await;
    assert_eq!(status, 401, "missing token is rejected");

    let (status, body) = http_get(handle.addr, &path, Some("s3cret")).await;
    assert_eq!(status, 200, "token admits the request");
    assert_eq!(body, format!("remote={}", handle.endpoint_id));

    let (status, _) = http_get(handle.addr, "/nope/fs/readme", Some("s3cret")).await;
    assert_eq!(status, 404, "unlisted ref is not resolved");

    handle.shutdown().await;
    accept.abort();
    drop(_h3);
    server.endpoint().close().await;
}
