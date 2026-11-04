//! HTTP/1.1 over an existing idfon iroh endpoint.
//!
//! This is the streaming sibling of `idfon-h3`: an embedder supplies an
//! [`axum::Router`] and [`serve_router`] serves it to dialing peers on the
//! daemon's own endpoint (same identity, same lifecycle as the message path).
//! Because the peer speaks real HTTP/1.1, `axum::extract::ws::WebSocketUpgrade`,
//! [`axum::response::Sse`] and streaming/chunked bodies all work **unmodified**
//! — no new protocol, no custom framing.
//!
//! [`H1Client`] is the other half: dial a peer by its [`EndpointAddr`], send a
//! request, and (for WebSockets) take the upgraded byte stream.
//!
//! # Shape
//!
//! One iroh connection carries one HTTP/1.1 connection, which carries one
//! request at a time — exactly like a browser's TCP connection. A WebSocket
//! session owns its connection for its whole lifetime. Parallel requests mean
//! parallel iroh connections.
//!
//! Peer identity is the dialing [`EndpointId`], handed to handlers through the
//! [`RemoteId`] request extension. There is no TLS, no `Host`/`Origin` check
//! and no token on this path: there is no browser to satisfy, and the QUIC
//! handshake already proves who dialed.
//!
//! `shortcut:` HTTP/1.1 only — no HTTP/2, no TLS, no content negotiation.
//! Callers that need multiplexed request/response (many concurrent requests on
//! one connection) should use the `idfon-h3` path instead.

use std::{io, sync::Arc};

use axum::{body::Body, extract::FromRequestParts, http::request::Parts, Extension, Router};
use bytes::Bytes;
use http::{header::HOST, HeaderValue, Request, Response, StatusCode};
use hyper::{
    body::Incoming, client::conn::http1 as client_http1, server::conn::http1 as server_http1,
    upgrade::Upgraded,
};
use hyper_util::{rt::TokioIo, service::TowerToHyperService};
use idfon_core::transport::{IrohTransport, SideChannelGuard, TransportError};
use iroh::{endpoint::Connection, EndpointAddr, EndpointId};
use tokio::{sync::mpsc, task::JoinHandle};

/// Re-exported so callers can read response bodies without matching versions.
pub use http_body_util::BodyExt;

/// Application protocol for HTTP/1.1 over iroh.
pub const ALPN: &[u8] = b"idfon/http1/1";

/// The [`EndpointId`] of the peer that dialed this connection, available to
/// handlers as a request extension / extractor.
///
/// This is the whole authorization story on the h1 path: the QUIC handshake
/// authenticated the peer, so a handler that trusts `RemoteId` trusts the
/// identity key — the same job as `idfon_h3::RemoteId`.
#[derive(Debug, Clone, Copy)]
#[repr(transparent)]
pub struct RemoteId(pub EndpointId);

impl<S> FromRequestParts<S> for RemoteId
where
    S: Sync,
{
    type Rejection = (StatusCode, &'static str);

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        parts.extensions.get().copied().ok_or((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Trying to extract RemoteId outside idfon-h1 context",
        ))
    }
}

/// A running HTTP/1.1 server. Dropping it stops accepting new connections (the
/// ALPN stays registered on the endpoint).
pub struct H1Server {
    _guard: SideChannelGuard,
    task: JoinHandle<()>,
}

impl Drop for H1Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Serves an axum `router` to peers over `transport`'s existing endpoint.
///
/// Run this alongside the transport's message accept loop
/// ([`IrohTransport::serve`]): that loop dispatches inbound connections by
/// ALPN, so without it no h1 connection is ever accepted. The h1, h3 and
/// message ALPNs coexist on one endpoint.
pub fn serve_router(transport: &Arc<IrohTransport>, router: Router) -> H1Server {
    let (tx, mut rx) = mpsc::channel(16);
    let guard = transport.add_side_channel(ALPN, tx);
    let task = tokio::spawn(async move {
        while let Some(connection) = rx.recv().await {
            let router = router.clone();
            tokio::spawn(async move { serve_connection(connection, router).await });
        }
    });
    H1Server {
        _guard: guard,
        task,
    }
}

async fn serve_connection(connection: Connection, router: Router) {
    let peer = connection.remote_id();
    let Ok((send, recv)) = connection.accept_bi().await else {
        tracing::debug!(target: "idfon.h1", %peer, "peer closed before opening a stream");
        return;
    };
    // The dialing identity travels in request extensions, like `idfon-h3`.
    // hyper 1 has its own `Service` trait, so the axum router is adapted.
    let app = TowerToHyperService::new(router.layer(Extension(RemoteId(peer))));
    // `join` is the duplex adapter: iroh's recv/send halves are a tokio reader
    // and writer, and `TokioIo` bridges them to hyper's IO traits.
    let io = TokioIo::new(tokio::io::join(recv, send));
    // `.with_upgrades()` is what makes `WebSocketUpgrade` work. SSE and
    // streaming bodies need nothing extra. hyper's defaults bound the request
    // line + headers (400 KiB buffer, 100 headers).
    if let Err(error) = server_http1::Builder::new()
        .serve_connection(io, app)
        .with_upgrades()
        .await
    {
        tracing::debug!(target: "idfon.h1", %peer, error = %error, "h1 connection ended");
    }
    // Do not close the QUIC connection here: after an upgrade hyper returns
    // while the WebSocket is still live, and the upgraded IO holds the stream
    // handles. Dropping our handle is enough — the connection closes when the
    // last stream goes away.
}

/// An HTTP/1.1 client bound to `transport`'s endpoint and identity.
///
/// Inbound h1 traffic is unaffected; this only dials out, so the peer sees the
/// daemon's usual endpoint id.
pub struct H1Client {
    transport: Arc<IrohTransport>,
}

impl H1Client {
    pub fn new(transport: &Arc<IrohTransport>) -> Self {
        Self {
            transport: Arc::clone(transport),
        }
    }

    /// Dials `peer` and opens one HTTP/1.1 connection over a fresh iroh
    /// bi-stream. Use this for streaming responses and WebSocket upgrades.
    pub async fn connect(&self, peer: &EndpointAddr) -> Result<H1Connection, TransportError> {
        let (connection, send, recv) = self.transport.open_bi_stream(peer, ALPN).await?;
        let io = TokioIo::new(tokio::io::join(recv, send));
        let (sender, driver) = client_http1::handshake::<_, Body>(io)
            .await
            .map_err(|error| TransportError::Failed(format!("h1 handshake: {error}")))?;
        let task = tokio::spawn(async move {
            if let Err(error) = driver.with_upgrades().await {
                tracing::debug!(target: "idfon.h1", error = %error, "h1 client connection ended");
            }
            // Keep the QUIC connection alive for as long as this driver (and
            // therefore any upgraded stream) runs.
            drop(connection);
        });
        Ok(H1Connection {
            peer: peer.id,
            sender,
            task,
        })
    }

    /// One-shot request: dial, send, collect the whole body, close.
    ///
    /// Fine for small payloads (JSON, a screenshot PNG). For large downloads
    /// or a streaming response body, use [`H1Client::connect`] and read the
    /// [`Incoming`] body yourself.
    pub async fn fetch(
        &self,
        peer: &EndpointAddr,
        request: Request<Body>,
    ) -> Result<Response<Bytes>, TransportError> {
        let mut connection = self.connect(peer).await?;
        let response = connection.send(request).await?;
        let (parts, body) = response.into_parts();
        let bytes = body
            .collect()
            .await
            .map_err(|error| TransportError::Failed(format!("h1 response body: {error}")))?
            .to_bytes();
        Ok(Response::from_parts(parts, bytes))
    }

    /// One-shot `GET` at `path`.
    pub async fn get(
        &self,
        peer: &EndpointAddr,
        path: &str,
    ) -> Result<Response<Bytes>, TransportError> {
        let request = Request::get(request_path(path))
            .body(Body::empty())
            .map_err(|error| TransportError::Failed(format!("h1 request: {error}")))?;
        self.fetch(peer, request).await
    }
}

/// One HTTP/1.1 connection to a peer.
///
/// Dropping it closes the connection. Keep it alive while reading a streaming
/// response body; after a WebSocket upgrade the upgraded stream is independent
/// and the connection may be dropped.
pub struct H1Connection {
    peer: EndpointId,
    sender: client_http1::SendRequest<Body>,
    task: JoinHandle<()>,
}

impl H1Connection {
    /// Sends one request on this connection.
    ///
    /// The `Host` header is filled in with the peer's endpoint id when the
    /// caller did not set one (HTTP/1.1 requires it).
    pub async fn send(
        &mut self,
        mut request: Request<Body>,
    ) -> Result<Response<Incoming>, TransportError> {
        if !request.headers().contains_key(HOST) {
            // An endpoint id is 64 lowercase hex chars: always a valid header.
            let host =
                HeaderValue::from_str(&self.peer.to_string()).expect("endpoint id is a header");
            request.headers_mut().insert(HOST, host);
        }
        self.sender
            .send_request(request)
            .await
            .map_err(|error| TransportError::Failed(format!("h1 request: {error}")))
    }
}

impl Drop for H1Connection {
    fn drop(&mut self) {
        // The driver owns the byte stream; aborting it drops the stream, which
        // closes the QUIC connection once nothing else holds it.
        self.task.abort();
    }
}

/// Resolves the upgraded byte stream of a `101 Switching Protocols` response.
///
/// Hand the result to any library that takes a tokio byte stream — e.g.
/// `tokio_tungstenite::WebSocketStream::from_raw_socket` — because the
/// WebSocket handshake itself already happened over HTTP/1.1.
pub async fn upgrade<B>(response: Response<B>) -> io::Result<TokioIo<Upgraded>> {
    let upgraded = hyper::upgrade::on(response)
        .await
        .map_err(io::Error::other)?;
    Ok(TokioIo::new(upgraded))
}

/// Builds the `iroh+h1://<endpoint-id><path>` address a peer is reachable at.
/// The scheme is nominal; the authority selects the peer.
pub fn uri(peer: EndpointId, path: &str) -> String {
    if path.starts_with('/') {
        format!("iroh+h1://{peer}{path}")
    } else {
        format!("iroh+h1://{peer}/{path}")
    }
}

fn request_path(path: &str) -> String {
    if path.starts_with('/') {
        path.to_owned()
    } else {
        format!("/{path}")
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use axum::{
        extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade},
        response::sse::{Event, Sse},
        routing::{get, post},
    };
    use bytes::Bytes;
    use futures_util::{stream, StreamExt};
    use http::{header::CONTENT_TYPE, Method};
    use idfon_protocol::MessageAck;
    use tokio::sync::{mpsc, oneshot};

    use super::*;

    type ServerTransport = Arc<IrohTransport>;

    /// Distinct identities per call: iroh's relay routes by endpoint id, so
    /// two tests sharing a key can dial each other's server.
    fn test_key() -> [u8; 32] {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let mut key = [0x5a; 32];
        key[..8].copy_from_slice(
            &NEXT
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                .to_le_bytes(),
        );
        key[8] = (std::process::id() & 0xff) as u8;
        key
    }

    /// Two real transports: `(server, client)`.
    async fn pair() -> (ServerTransport, ServerTransport) {
        let server = Arc::new(
            IrohTransport::bind_with_key(Some(test_key()))
                .await
                .expect("server binds"),
        );
        let client = IrohTransport::bind_with_key(Some(test_key()))
            .await
            .expect("client binds");
        let _ = tokio::time::timeout(Duration::from_secs(5), server.endpoint().online()).await;
        let _ = tokio::time::timeout(Duration::from_secs(5), client.endpoint().online()).await;
        (server, Arc::new(client))
    }

    /// The side-channel dispatch only runs while the transport accepts.
    fn accept_messages(transport: &ServerTransport) -> JoinHandle<()> {
        let transport = Arc::clone(transport);
        tokio::spawn(async move {
            let _ = transport
                .serve(|_| async {
                    Err::<MessageAck, TransportError>(TransportError::Failed(
                        "message path unused in h1 test".into(),
                    ))
                })
                .await;
        })
    }

    async fn get_body(client: &H1Client, peer: &EndpointAddr, path: &str) -> Bytes {
        client
            .get(peer, path)
            .await
            .expect("get succeeds")
            .into_body()
    }

    /// Plain GET, peer identity in extensions, a chunked (streamed) request
    /// body, and an SSE response that streams — plus cleanup when the reader
    /// goes away.
    #[tokio::test]
    async fn get_chunked_post_sse_and_peer_identity() {
        let (server, client_transport) = pair().await;
        let (events_tx, events_rx) = mpsc::channel::<String>(4);
        let events_rx = Arc::new(std::sync::Mutex::new(Some(events_rx)));

        let app = Router::new()
            .route(
                "/whoami",
                get(|RemoteId(peer): RemoteId| async move { peer.to_string() }),
            )
            .route(
                "/echo",
                post(|body: Bytes| async move {
                    format!("{}:{}", body.len(), String::from_utf8_lossy(&body))
                }),
            )
            .route(
                "/sse",
                get(move || {
                    let rx = events_rx
                        .lock()
                        .expect("events mutex")
                        .take()
                        .expect("sse handler runs once");
                    async move {
                        let events = stream::unfold(rx, |mut rx| async move {
                            rx.recv().await.map(|item| {
                                (Ok::<_, std::io::Error>(Event::default().data(item)), rx)
                            })
                        });
                        Sse::new(events)
                    }
                }),
            );

        let _h1 = serve_router(&server, app);
        let accept = accept_messages(&server);
        let addr = server.endpoint().addr();
        let client = H1Client::new(&client_transport);

        // Plain GET, and the dialing EndpointId is what the handler sees.
        let who = get_body(&client, &addr, "/whoami").await;
        assert_eq!(
            who.as_ref(),
            client_transport.endpoint().id().to_string().as_bytes()
        );

        // Keep-alive: two requests, sequentially, on one h1 connection.
        let expected = client_transport.endpoint().id().to_string();
        let mut connection = client.connect(&addr).await.expect("connect");
        for _ in 0..2 {
            let response = connection
                .send(
                    Request::get("/whoami")
                        .body(Body::empty())
                        .expect("keep-alive request"),
                )
                .await
                .expect("keep-alive response");
            assert_eq!(response.status(), StatusCode::OK);
            let body = response
                .into_body()
                .collect()
                .await
                .expect("keep-alive body")
                .to_bytes();
            assert_eq!(body.as_ref(), expected.as_bytes());
        }
        drop(connection);

        // No Content-Length (a stream), so hyper frames it chunked.
        let body = Body::from_stream(stream::iter(vec![
            Ok::<_, std::io::Error>(Bytes::from_static(b"hello ")),
            Ok(Bytes::from_static(b"chunked")),
        ]));
        let response = client
            .fetch(&addr, Request::post("/echo").body(body).expect("request"))
            .await
            .expect("post succeeds");
        assert_eq!(response.body().as_ref(), b"13:hello chunked");

        // SSE streams: the second event is not written until the first is read.
        let mut connection = client.connect(&addr).await.expect("connect");
        let response = connection
            .send(
                Request::get("/sse")
                    .body(Body::empty())
                    .expect("sse request"),
            )
            .await
            .expect("sse response");
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[CONTENT_TYPE], "text/event-stream");
        let mut body = response.into_body();

        events_tx.send("one".into()).await.expect("send event one");
        let chunk = body
            .frame()
            .await
            .expect("first frame")
            .expect("first frame ok")
            .into_data()
            .expect("first frame is data");
        assert!(String::from_utf8_lossy(&chunk).contains("data: one"));

        events_tx.send("two".into()).await.expect("send event two");
        let chunk = body
            .frame()
            .await
            .expect("second frame")
            .expect("second frame ok")
            .into_data()
            .expect("second frame is data");
        assert!(String::from_utf8_lossy(&chunk).contains("data: two"));

        // Dropping the reader tears the handler's stream down.
        drop(body);
        drop(connection);
        tokio::time::timeout(Duration::from_secs(5), events_tx.closed())
            .await
            .expect("sse stream dropped with the connection");

        accept.abort();
        server.endpoint().close().await;
        client_transport.endpoint().close().await;
    }

    /// A standard `WebSocketUpgrade` handler works unmodified: RFC 6455
    /// handshake over the upgraded stream, binary both ways, clean close.
    #[tokio::test]
    async fn websocket_echoes_and_closes_cleanly() {
        use futures_util::SinkExt;
        use tokio_tungstenite::{
            tungstenite::{protocol::Role, Message as SocketMessage},
            WebSocketStream,
        };

        let (server, client_transport) = pair().await;
        let (closed_tx, closed_rx) = oneshot::channel::<()>();
        let closed_tx = Arc::new(std::sync::Mutex::new(Some(closed_tx)));

        let app = Router::new().route(
            "/ws",
            get(move |upgrade: WebSocketUpgrade| {
                let closed_tx = Arc::clone(&closed_tx);
                async move { upgrade.on_upgrade(move |socket| echo(socket, closed_tx)) }
            }),
        );
        let _h1 = serve_router(&server, app);
        let accept = accept_messages(&server);
        let addr = server.endpoint().addr();
        let client = H1Client::new(&client_transport);

        let mut connection = client.connect(&addr).await.expect("connect");
        let request = Request::builder()
            .method(Method::GET)
            .uri("/ws")
            .header("connection", "upgrade")
            .header("upgrade", "websocket")
            .header("sec-websocket-version", "13")
            .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
            .body(Body::empty())
            .expect("ws request");
        let response = connection.send(request).await.expect("ws handshake");
        assert_eq!(response.status(), StatusCode::SWITCHING_PROTOCOLS);

        let io = upgrade(response).await.expect("upgrade");
        let mut socket = WebSocketStream::from_raw_socket(io, Role::Client, None).await;

        socket
            .send(SocketMessage::Text("ping".into()))
            .await
            .expect("send text");
        match socket.next().await.expect("echo").expect("echo ok") {
            SocketMessage::Text(text) => assert_eq!(text.as_str(), "ping"),
            other => panic!("unexpected message: {other:?}"),
        }

        // 2 MiB server->client->server: the stream must carry more than one
        // QUIC flow-control window without stalling.
        let payload = Bytes::from(vec![7u8; 2 * 1024 * 1024]);
        socket
            .send(SocketMessage::Binary(payload.clone()))
            .await
            .expect("send binary");
        match socket.next().await.expect("binary echo").expect("echo ok") {
            SocketMessage::Binary(data) => assert_eq!(data.len(), payload.len()),
            other => panic!("unexpected message: {other:?}"),
        }

        socket.close(None).await.expect("close");
        // The upgraded socket outlives hyper's connection future; the server
        // only signals after its handler loop ended.
        tokio::time::timeout(Duration::from_secs(5), closed_rx)
            .await
            .expect("server saw the socket close")
            .expect("server handler signaled");

        // A stock WS client that only takes a byte stream works too: no
        // idfon-h1 client code, tungstenite performs the RFC 6455 handshake
        // itself over a raw bi-stream.
        let (connection, send, recv) = client_transport
            .open_bi_stream(&addr, ALPN)
            .await
            .expect("dial");
        let raw = tokio::io::join(recv, send);
        let (mut socket, response) = tokio_tungstenite::client_async("ws://idfon/ws", raw)
            .await
            .expect("stock ws handshake");
        assert_eq!(response.status(), StatusCode::SWITCHING_PROTOCOLS);
        socket
            .send(SocketMessage::Text("stock".into()))
            .await
            .expect("send text");
        match socket.next().await.expect("echo").expect("echo ok") {
            SocketMessage::Text(text) => assert_eq!(text.as_str(), "stock"),
            other => panic!("unexpected message: {other:?}"),
        }
        socket.close(None).await.expect("close");
        drop(connection);

        accept.abort();
        server.endpoint().close().await;
        client_transport.endpoint().close().await;
    }

    async fn echo(
        mut socket: WebSocket,
        closed: Arc<std::sync::Mutex<Option<oneshot::Sender<()>>>>,
    ) {
        while let Some(Ok(message)) = socket.recv().await {
            match message {
                WsMessage::Text(text) => {
                    if socket.send(WsMessage::Text(text)).await.is_err() {
                        break;
                    }
                }
                WsMessage::Binary(data) => {
                    if socket.send(WsMessage::Binary(data)).await.is_err() {
                        break;
                    }
                }
                WsMessage::Close(_) => break,
                _ => {}
            }
        }
        if let Some(tx) = closed.lock().expect("closed mutex").take() {
            let _ = tx.send(());
        }
    }

    /// h1, h3 and the message ALPN share one endpoint and identity.
    #[tokio::test]
    async fn h1_h3_and_message_path_coexist() {
        let (server, client_transport) = pair().await;
        let _h1 = serve_router(
            &server,
            Router::new().route("/h1", get(|| async { "over h1" })),
        );
        let _h3 = idfon_h3::serve_router(
            &server,
            Router::new().route("/h3", get(|| async { "over h3" })),
        );
        let accept = accept_messages(&server);
        let addr = server.endpoint().addr();

        let client = H1Client::new(&client_transport);
        assert_eq!(get_body(&client, &addr, "/h1").await.as_ref(), b"over h1");

        let h3 = idfon_h3::H3Client::new(&client_transport).expect("h3 client");
        h3.add_address(&addr);
        let response = h3.get(&addr, "/h3").send().await.expect("h3 request");
        assert_eq!(response.text().await.expect("h3 body"), "over h3");

        accept.abort();
        server.endpoint().close().await;
        client_transport.endpoint().close().await;
    }

    /// Opens a WebSocket on `peer` and returns the client-side stream.
    async fn ws_open(
        client: &H1Client,
        peer: &EndpointAddr,
    ) -> tokio_tungstenite::WebSocketStream<TokioIo<Upgraded>> {
        use tokio_tungstenite::{tungstenite::protocol::Role, WebSocketStream};
        let mut connection = client.connect(peer).await.expect("ws connect");
        let request = Request::builder()
            .method(Method::GET)
            .uri("/ws")
            .header("connection", "upgrade")
            .header("upgrade", "websocket")
            .header("sec-websocket-version", "13")
            .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
            .body(Body::empty())
            .expect("ws request");
        let response = connection.send(request).await.expect("ws handshake");
        assert_eq!(response.status(), StatusCode::SWITCHING_PROTOCOLS);
        let io = upgrade(response).await.expect("upgrade");
        WebSocketStream::from_raw_socket(io, Role::Client, None).await
    }

    /// Echoes `count` frames of `size` bytes and reports round-trip percentiles.
    /// The p95 is the ceiling for a stop-and-wait protocol (one frame in flight,
    /// ack before the next); a streaming sender is bounded by bandwidth instead.
    async fn measure_frames<S, E>(label: &str, socket: &mut S, size: usize, count: usize)
    where
        S: futures_util::Sink<tokio_tungstenite::tungstenite::Message, Error = E>
            + futures_util::Stream<Item = Result<tokio_tungstenite::tungstenite::Message, E>>
            + Unpin,
        E: std::fmt::Debug,
    {
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::tungstenite::Message;
        let frame = Bytes::from(vec![0xa5; size]);
        let mut samples = Vec::with_capacity(count);
        for _ in 0..count {
            let started = std::time::Instant::now();
            socket
                .send(Message::Binary(frame.clone()))
                .await
                .expect("send frame");
            match socket.next().await.expect("echo").expect("echo ok") {
                Message::Binary(data) => assert_eq!(data.len(), size),
                other => panic!("unexpected message: {other:?}"),
            }
            samples.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        samples.sort_by(|a, b| a.partial_cmp(b).expect("finite"));
        let p50 = samples[count / 2];
        let p95 = samples[(count * 95 / 100).min(count - 1)];
        eprintln!(
            "MEASURE {label}: {size}B x{count} round trip — p50 {p50:.2} ms, p95 {p95:.2} ms, max {:.2} ms; stop-and-wait ceiling {:.0} fps at p95",
            samples[count - 1],
            1000.0 / p95
        );
    }

    /// Measures h1 against h3 over a *direct* QUIC path (loopback). The
    /// advertised addresses can resolve to the relay instead — on a host with
    /// VPN-assigned interfaces both endpoints end up relayed at ~10 Mbps — so
    /// this dials the server's bound port on 127.0.0.1 explicitly.
    ///
    /// Run with `cargo test -p idfon-h1 -- --ignored --nocapture throughput`.
    #[tokio::test]
    #[ignore = "throughput bench, not a functional assertion"]
    async fn throughput_over_a_direct_path() {
        let (server, client_transport) = pair().await;
        let payload = Bytes::from(vec![7u8; 12 * 1024 * 1024]);
        let download = payload.clone();
        let app = Router::new()
            .route(
                "/blob",
                get(move || {
                    let p = download.clone();
                    async move { p }
                }),
            )
            .route(
                "/sink",
                post(|body: Bytes| async move { body.len().to_string() }),
            )
            .route(
                "/ws",
                get(|ws: WebSocketUpgrade| async move {
                    ws.on_upgrade(|socket| echo(socket, Arc::new(std::sync::Mutex::new(None))))
                }),
            )
            .layer(axum::extract::DefaultBodyLimit::disable());
        let h3 = idfon_h3::serve_router(
            &server,
            Router::new().route("/blob", {
                let download = payload.clone();
                get(move || {
                    let p = download.clone();
                    async move { p }
                })
            }),
        );
        let _h1 = serve_router(&server, app);
        let accept = accept_messages(&server);
        let addr = server.endpoint().addr();
        // Relay-only endpoints publish no IP sockets, so `bound_sockets()` is
        // empty; only build the explicit-loopback address when there is one.
        let direct = server.endpoint().bound_sockets().first().map(|socket| {
            EndpointAddr::from_parts(
                addr.id,
                [iroh::TransportAddr::Ip(
                    (std::net::Ipv4Addr::LOCALHOST, socket.port()).into(),
                )],
            )
        });
        let client = H1Client::new(&client_transport);

        // `IDFON_RELAY_ONLY=1` forces the relay path (idfon-core clears the IP
        // transports); the explicit-loopback dial cannot work then.
        let relay_only = std::env::var("IDFON_RELAY_ONLY")
            .is_ok_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes"));
        let target = match (&direct, relay_only) {
            (Some(direct), false) => direct.clone(),
            _ => addr.clone(),
        };
        let (probe, _send, _recv) = client_transport
            .open_bi_stream(&target, ALPN)
            .await
            .expect("probe dial");
        eprintln!(
            "PATH {}({}): {:?}",
            if relay_only { "relay-only " } else { "direct " },
            if relay_only {
                "advertised"
            } else {
                "127.0.0.1"
            },
            probe.paths()
        );
        probe.close(0u32.into(), b"probe");

        let started = std::time::Instant::now();
        let response = client.get(&target, "/blob").await.expect("h1 download");
        let elapsed = started.elapsed();
        assert_eq!(response.body().len(), payload.len());
        eprintln!(
            "MEASURE h1 download 12 MiB in {:?} = {:.1} MiB/s ({:.0} Mbps)",
            elapsed,
            12.0 / elapsed.as_secs_f64(),
            12.0 * 8.0 * 1.048576 / elapsed.as_secs_f64()
        );

        let h3client = idfon_h3::H3Client::new(&client_transport).expect("h3 client");
        h3client.add_address(&addr);
        let started = std::time::Instant::now();
        let response = h3client
            .get(&target, "/blob")
            .send()
            .await
            .expect("h3 request");
        let body = response.bytes().await.expect("h3 body");
        let elapsed = started.elapsed();
        assert_eq!(body.len(), payload.len());
        eprintln!(
            "MEASURE h3 download 12 MiB in {:?} = {:.1} MiB/s ({:.0} Mbps)",
            elapsed,
            12.0 / elapsed.as_secs_f64(),
            12.0 * 8.0 * 1.048576 / elapsed.as_secs_f64()
        );

        let started = std::time::Instant::now();
        let response = client
            .fetch(
                &target,
                Request::post("/sink")
                    .body(Body::from(payload.clone()))
                    .expect("req"),
            )
            .await
            .expect("upload");
        let elapsed = started.elapsed();
        eprintln!(
            "MEASURE h1 upload 12 MiB in {:?} = {:.1} MiB/s ({:.0} Mbps) body={:?}",
            elapsed,
            12.0 / elapsed.as_secs_f64(),
            12.0 * 8.0 * 1.048576 / elapsed.as_secs_f64(),
            response.body()
        );

        // Frame latency on the direct path: a 1 KiB control message and a
        // 64 KiB payload (roughly a compressed 1080p frame).
        let mut socket = ws_open(&client, &target).await;
        measure_frames("h1 ws direct", &mut socket, 1024, 200).await;
        measure_frames("h1 ws direct", &mut socket, 64 * 1024, 100).await;
        socket.close(None).await.expect("close");

        if !relay_only {
            // The advertised address on a normal run (relay or LAN, whichever
            // iroh selects); skipped when relay-only, where it is `target`.
            let mut socket = ws_open(&client, &addr).await;
            measure_frames("h1 ws advertised", &mut socket, 1024, 60).await;
            measure_frames("h1 ws advertised", &mut socket, 64 * 1024, 30).await;
            socket.close(None).await.expect("close");
        }

        accept.abort();
        drop(h3);
        server.endpoint().close().await;
        client_transport.endpoint().close().await;
    }

    /// The baseline the whole decision rests on: plain TCP WebSocket echo on
    /// loopback, same frame sizes as the iroh bench. Anything iroh adds over
    /// this is QUIC's cost, not the adapter's.
    #[tokio::test]
    #[ignore = "throughput bench; needs no network"]
    async fn tcp_ws_baseline() {
        use futures_util::{SinkExt, StreamExt};
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let addr = listener.local_addr().expect("addr");
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("accept");
            let mut socket = tokio_tungstenite::accept_async(stream)
                .await
                .expect("handshake");
            while let Some(Ok(message)) = socket.next().await {
                if message.is_binary() || message.is_text() {
                    socket.send(message).await.expect("echo");
                }
            }
        });
        let stream = tokio::net::TcpStream::connect(addr).await.expect("connect");
        let (mut socket, _) = tokio_tungstenite::client_async("ws://127.0.0.1/ws", stream)
            .await
            .expect("handshake");
        measure_frames("tcp ws", &mut socket, 1024, 200).await;
        measure_frames("tcp ws", &mut socket, 64 * 1024, 100).await;
        socket.close(None).await.expect("close");
        server.await.expect("server");

        // Raw TCP bulk echo, 12 MiB each way, same payload as the h1 bench.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let addr = listener.local_addr().expect("addr");
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept");
            let mut buf = vec![0u8; 12 * 1024 * 1024];
            stream.read_exact(&mut buf).await.expect("read");
            stream.write_all(&buf).await.expect("write");
        });
        let mut stream = tokio::net::TcpStream::connect(addr).await.expect("connect");
        let payload = vec![7u8; 12 * 1024 * 1024];
        let started = std::time::Instant::now();
        stream.write_all(&payload).await.expect("write");
        let mut back = vec![0u8; payload.len()];
        stream.read_exact(&mut back).await.expect("read");
        let elapsed = started.elapsed();
        assert_eq!(back, payload);
        eprintln!(
            "MEASURE tcp bulk 12 MiB round trip in {:?} = {:.1} MiB/s ({:.0} Mbps each way)",
            elapsed,
            12.0 / elapsed.as_secs_f64(),
            12.0 * 8.0 * 1.048576 / elapsed.as_secs_f64()
        );
        server.await.expect("server");
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
