//! End-to-end proof of the edge: a peer serves one route over H3, and the edge
//! bridges an HTTP request to it. Also asserts requester auth (bearer token and
//! capability ticket) and the endpoint-id allow-list.

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use idfon_core::transport::{IrohTransport, TransportError};
use idfon_edge::{run, EdgeAuth, EdgeConfig};
use idfon_h3::{serve_router, H3Server, RemoteId};
use idfon_protocol::{Capability, MessageAck};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Reports the endpoint id the peer saw and whether the edge forwarded a
/// caller ticket, so the test can prove both the edge identity and transparency.
async fn readme(RemoteId(remote): RemoteId, headers: axum::http::HeaderMap) -> Response {
    let ticket = headers.contains_key("x-idfon-ticket");
    (
        axum::http::StatusCode::OK,
        format!("remote={remote} ticket={ticket}"),
    )
        .into_response()
}

/// A peer transport serving `/fs/readme` over H3, its accept loop, and its id.
async fn start_peer(
    peer_key: [u8; 32],
) -> (
    Arc<IrohTransport>,
    H3Server,
    tokio::task::JoinHandle<()>,
    String,
) {
    let server = Arc::new(
        IrohTransport::bind_with_key(Some(peer_key))
            .await
            .expect("peer binds"),
    );
    let h3 = serve_router(&server, Router::new().route("/fs/readme", get(readme)));
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
    let endpoint_id = server.endpoint().id().to_string();
    (server, h3, accept, endpoint_id)
}

async fn http_get(addr: SocketAddr, path: &str, headers: &[(&str, String)]) -> (u16, String) {
    let mut stream = tokio::net::TcpStream::connect(addr)
        .await
        .expect("connect edge");
    let mut request = format!("GET {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n");
    for (name, value) in headers {
        request.push_str(&format!("{name}: {value}\r\n"));
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
async fn edge_bridges_and_gates_with_a_token() {
    let (server, h3, accept, peer_id) = start_peer([21; 32]).await;

    let handle = run(EdgeConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        key: [22; 32],
        allow: HashSet::from([peer_id.clone()]),
        pins: HashMap::from([(peer_id.clone(), server.endpoint().addr())]),
        domain: None,
        auth: EdgeAuth::Token("s3cret".into()),
        tls: None,
        health_path: Some("/healthz".into()),
        rate_limit_per_minute: 0,
    })
    .await
    .expect("edge runs");

    let path = format!("/{peer_id}/fs/readme");
    let auth = ("Authorization", "Bearer s3cret".to_owned());

    // Health bypasses requester auth.
    let (status, body) = http_get(handle.addr, "/healthz", &[]).await;
    assert_eq!(status, 200);
    assert_eq!(body, "ok");

    let (status, _) = http_get(handle.addr, &path, &[]).await;
    assert_eq!(status, 401, "missing token is rejected");

    let (status, body) = http_get(handle.addr, &path, std::slice::from_ref(&auth)).await;
    assert_eq!(status, 200, "token admits the request");
    assert_eq!(body, format!("remote={} ticket=false", handle.endpoint_id));

    let (status, _) = http_get(handle.addr, "/nope/fs/readme", &[auth]).await;
    assert_eq!(status, 404, "unlisted ref is not resolved");

    handle.shutdown().await;
    accept.abort();
    drop(h3);
    server.endpoint().close().await;
}

#[tokio::test]
async fn edge_accepts_a_capability_ticket() {
    let (server, h3, accept, peer_id) = start_peer([23; 32]).await;

    let handle = run(EdgeConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        key: [24; 32],
        allow: HashSet::from([peer_id.clone()]),
        pins: HashMap::from([(peer_id.clone(), server.endpoint().addr())]),
        domain: None,
        auth: EdgeAuth::Ticket {
            capability: "web.fetch".into(),
        },
        tls: None,
        health_path: Some("/healthz".into()),
        rate_limit_per_minute: 0,
    })
    .await
    .expect("edge runs");

    let path = format!("/{peer_id}/fs/readme");
    let issuer = idfon_core::generate_identity();
    let expiry = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 3600;

    // No ticket -> 401.
    let (status, _) = http_get(handle.addr, &path, &[]).await;
    assert_eq!(status, 401, "no ticket is rejected");

    // A ticket with the required capability -> 200, and the edge forwards it
    // to the peer (transparent: the peer sees the caller's credential).
    let ticket = idfon_core::issue_capability_ticket(
        &issuer,
        Some(peer_id.clone()),
        vec![Capability::new("web.fetch")],
        Some(expiry.to_string()),
        "edge-test",
    );
    let ticket_json = serde_json::to_string(&ticket).unwrap();
    let (status, body) = http_get(handle.addr, &path, &[("x-idfon-ticket", ticket_json)]).await;
    assert_eq!(status, 200, "capability ticket admits the request");
    assert_eq!(body, format!("remote={} ticket=true", handle.endpoint_id));

    // A ticket missing the required capability is rejected.
    let wrong_cap = idfon_core::issue_capability_ticket(
        &issuer,
        Some(peer_id.clone()),
        vec![Capability::new("message.receive")],
        Some(expiry.to_string()),
        "edge-test",
    );
    let wrong_json = serde_json::to_string(&wrong_cap).unwrap();
    let (status, _) = http_get(handle.addr, &path, &[("x-idfon-ticket", wrong_json)]).await;
    assert_eq!(status, 401, "missing capability is rejected");

    // An expired ticket is rejected.
    let expired = idfon_core::issue_capability_ticket(
        &issuer,
        Some(peer_id.clone()),
        vec![Capability::new("web.fetch")],
        Some("1".to_owned()),
        "edge-test",
    );
    let expired_json = serde_json::to_string(&expired).unwrap();
    let (status, _) = http_get(handle.addr, &path, &[("x-idfon-ticket", expired_json)]).await;
    assert_eq!(status, 401, "expired ticket is rejected");

    handle.shutdown().await;
    accept.abort();
    drop(h3);
    server.endpoint().close().await;
}

#[tokio::test]
async fn edge_rate_limits_per_caller() {
    let (server, h3, accept, peer_id) = start_peer([25; 32]).await;

    let handle = run(EdgeConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        key: [26; 32],
        allow: HashSet::from([peer_id.clone()]),
        pins: HashMap::from([(peer_id.clone(), server.endpoint().addr())]),
        domain: None,
        auth: EdgeAuth::Token("s3cret".into()),
        tls: None,
        health_path: None,
        rate_limit_per_minute: 1,
    })
    .await
    .expect("edge runs");

    let path = format!("/{peer_id}/fs/readme");
    let auth = ("Authorization", "Bearer s3cret".to_owned());

    let (status, _) = http_get(handle.addr, &path, &[auth.clone()]).await;
    assert_eq!(status, 200, "first request is admitted");
    let (status, _) = http_get(handle.addr, &path, &[auth]).await;
    assert_eq!(status, 403, "second request in the window is rate limited");

    handle.shutdown().await;
    accept.abort();
    drop(h3);
    server.endpoint().close().await;
}
