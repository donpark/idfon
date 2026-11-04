//! Message channels over an existing idfon iroh endpoint, with no HTTP.
//!
//! The WebSocket *interface* (text/binary messages, ordered, reliable, close)
//! mapped straight onto [`iroh`] bi-streams: one channel owns one stream, so
//! messages keep the ordering and reliability the transport gives them and
//! nothing is wrapped in HTTP/1.1, an upgrade, or a second framing layer that
//! RFC 6455 would add on top.
//!
//! The wire form is one frame per message:
//!
//! ```text
//! [kind: u8][len: u32 LE][payload]
//! ```
//!
//! A channel is opened by sending its name as the first frame (server side:
//! the handler receives that name; client side: [`ChannelClient::connect`]
//! sends it). One connection per channel is what shards it: see
//! [`serve_channels`].
//!
//! `shortcut:` no fragmentation, no ping/pong, no extension negotiation — the
//! three RFC 6455 features this API does not need. A message is bounded by
//! [`MAX_MESSAGE_BYTES`] (`16 MiB`). Callers that need the RFC verbatim (a
//! browser-adjacent client, an existing `axum` handler) use the `idfon-h1` path.

use std::sync::Arc;

use bytes::Bytes;
use idfon_core::transport::{IrohTransport, SideChannelGuard, TransportError};
use iroh::{
    endpoint::{Connection, ReadExactError, RecvStream, SendStream},
    EndpointAddr, EndpointId,
};
use tokio::{sync::mpsc, task::JoinHandle};

/// Application protocol for message channels.
pub const ALPN: &[u8] = b"idfon/channel/1";

/// Largest single message, matching what the media paths already move.
pub const MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;

/// Longest channel name accepted. A name is a routing key, not payload: an
/// untrusted peer must not be able to make the server hold a 16 MiB label.
pub const MAX_CHANNEL_NAME: usize = 256;

const KIND_TEXT: u8 = 0;
const KIND_BINARY: u8 = 1;
const HEADER_BYTES: usize = 5;

/// A message to send. Borrowed, so a hot loop does not copy the payload.
#[derive(Debug, Clone, Copy)]
pub enum Message<'a> {
    Text(&'a str),
    Binary(&'a [u8]),
}

/// A received message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Received {
    Text(String),
    Binary(Bytes),
}

/// One open channel: the WebSocket-shaped handle over a QUIC bi-stream.
///
/// Dropping it closes the channel (the connection handle goes with it).
pub struct Channel {
    send: SendStream,
    recv: RecvStream,
    // Keeps the QUIC connection alive for as long as the channel is open.
    _connection: Connection,
    ended: bool,
}

impl Channel {
    /// Sends one message. Fails if the peer reset the stream.
    pub async fn send(&mut self, message: Message<'_>) -> Result<(), TransportError> {
        let (kind, payload) = match message {
            Message::Text(text) => (KIND_TEXT, text.as_bytes()),
            Message::Binary(data) => (KIND_BINARY, data),
        };
        if payload.len() > MAX_MESSAGE_BYTES {
            return Err(TransportError::MessageTooLarge);
        }
        let mut frame = Vec::with_capacity(HEADER_BYTES + payload.len());
        frame.push(kind);
        frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        frame.extend_from_slice(payload);
        self.send
            .write_all(&frame)
            .await
            .map_err(|error| TransportError::Failed(format!("channel send: {error}")))
    }

    /// Reads the next message. `None` means the peer closed the channel.
    pub async fn recv(&mut self) -> Result<Option<Received>, TransportError> {
        if self.ended {
            return Ok(None);
        }
        let mut header = [0u8; HEADER_BYTES];
        if let Err(error) = self.recv.read_exact(&mut header).await {
            // A clean peer close is a zero-byte finish, not an error.
            if matches!(error, ReadExactError::FinishedEarly(0)) {
                self.ended = true;
                return Ok(None);
            }
            return Err(TransportError::Failed(format!("channel recv: {error}")));
        }
        let length = u32::from_le_bytes([header[1], header[2], header[3], header[4]]) as usize;
        if length > MAX_MESSAGE_BYTES {
            return Err(TransportError::MessageTooLarge);
        }
        let mut payload = vec![0u8; length];
        self.recv
            .read_exact(&mut payload)
            .await
            .map_err(|error| TransportError::Failed(format!("channel recv: {error}")))?;
        Ok(Some(match header[0] {
            KIND_BINARY => Received::Binary(payload.into()),
            // Lossy, like a text-only consumer of any WS library: a text frame
            // is UTF-8 by contract, and one bad peer must not kill the channel.
            _ => Received::Text(String::from_utf8_lossy(&payload).into_owned()),
        }))
    }

    /// Closes the send half. The peer's `recv` then returns `None`.
    pub fn close(mut self) {
        let _ = self.send.finish();
    }
}

/// Dials channels on a peer.
pub struct ChannelClient {
    transport: Arc<IrohTransport>,
}

impl ChannelClient {
    pub fn new(transport: &Arc<IrohTransport>) -> Self {
        Self {
            transport: Arc::clone(transport),
        }
    }

    /// Dials `peer` and opens `name` as a fresh channel (its own QUIC
    /// connection, so its flow control and ordering are independent of every
    /// other channel).
    pub async fn connect(
        &self,
        peer: &EndpointAddr,
        name: &str,
    ) -> Result<Channel, TransportError> {
        let (connection, send, recv) = self.transport.open_bi_stream(peer, ALPN).await?;
        let mut channel = Channel {
            send,
            recv,
            _connection: connection,
            ended: false,
        };
        channel.send(Message::Text(name)).await?;
        Ok(channel)
    }
}

/// A running channel server. Dropping it stops accepting new channels (the
/// ALPN stays registered on the endpoint).
pub struct ChannelServer {
    _guard: SideChannelGuard,
    task: JoinHandle<()>,
}

impl Drop for ChannelServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Serves channels opened by peers on `transport`'s endpoint.
///
/// The handler runs once per channel, with the dialing peer's identity, the
/// channel name the client sent, and the channel itself. Run it alongside the
/// transport's message accept loop ([`IrohTransport::serve`]): that loop
/// dispatches inbound connections by ALPN.
///
/// Sharding is the caller's choice of channel names: one name per logical
/// stream (`control`, `audio`, `video`) means each gets its own connection, so
/// a consumer that stops draining `video` cannot stall `control`.
pub fn serve_channels<F, Fut>(transport: &Arc<IrohTransport>, handler: F) -> ChannelServer
where
    F: Fn(EndpointId, String, Channel) -> Fut + Clone + Send + Sync + 'static,
    Fut: std::future::Future<Output = ()> + Send + 'static,
{
    let (tx, mut rx) = mpsc::channel(16);
    let guard = transport.add_side_channel(ALPN, tx);
    let task = tokio::spawn(async move {
        while let Some(connection) = rx.recv().await {
            let handler = handler.clone();
            tokio::spawn(async move {
                let peer = connection.remote_id();
                let Ok((send, recv)) = connection.accept_bi().await else {
                    tracing::debug!(target: "idfon.channel", %peer, "peer closed before opening a channel");
                    return;
                };
                let mut channel = Channel {
                    send,
                    recv,
                    _connection: connection,
                    ended: false,
                };
                // First frame is the channel name, so one endpoint can serve
                // many shards without an HTTP request line or path.
                match channel.recv().await {
                    Ok(Some(Received::Text(name))) if name.len() <= MAX_CHANNEL_NAME => {
                        handler(peer, name, channel).await
                    }
                    Ok(Some(Received::Text(name))) => {
                        tracing::debug!(
                            target: "idfon.channel", %peer, len = name.len(),
                            "channel name too long (max {MAX_CHANNEL_NAME}), dropping"
                        );
                    }
                    other => {
                        tracing::debug!(target: "idfon.channel", %peer, ?other, "channel name missing");
                    }
                }
            });
        }
    });
    ChannelServer {
        _guard: guard,
        task,
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use idfon_protocol::MessageAck;
    use tokio::sync::oneshot;

    use super::*;

    /// Distinct identities per call: iroh routes by endpoint id, so two tests
    /// sharing a key can dial each other's server.
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
    async fn pair() -> (Arc<IrohTransport>, Arc<IrohTransport>) {
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
    fn accept_messages(transport: &Arc<IrohTransport>) -> JoinHandle<()> {
        let transport = Arc::clone(transport);
        tokio::spawn(async move {
            let _ = transport
                .serve(|_| async {
                    Err::<MessageAck, TransportError>(TransportError::Failed(
                        "message path unused in channel test".into(),
                    ))
                })
                .await;
        })
    }

    /// Echoes messages back, remembering the peer's close.
    async fn echo(mut channel: Channel, closed: Arc<std::sync::Mutex<Option<oneshot::Sender<()>>>>) {
        while let Ok(Some(message)) = channel.recv().await {
            let sent = match message {
                Received::Text(text) => channel.send(Message::Text(&text)).await,
                Received::Binary(data) => channel.send(Message::Binary(&data)).await,
            };
            if sent.is_err() {
                break;
            }
        }
        if let Some(tx) = closed.lock().expect("closed mutex").take() {
            let _ = tx.send(());
        }
    }

    /// Text and a 2 MiB binary payload (> one QUIC stream window) round trip,
    /// the channel name reaches the handler, and a close tears the handler down.
    #[tokio::test]
    async fn messages_round_trip_and_close() {
        let (server, client_transport) = pair().await;
        let (closed_tx, closed_rx) = oneshot::channel::<()>();
        let closed_tx = Arc::new(std::sync::Mutex::new(Some(closed_tx)));
        let (name_tx, name_rx) = oneshot::channel::<String>();
        let name_tx = Arc::new(std::sync::Mutex::new(Some(name_tx)));

        let _server = serve_channels(&server, move |_peer, name, channel| {
            let closed = Arc::clone(&closed_tx);
            let name_tx = Arc::clone(&name_tx);
            if let Some(tx) = name_tx.lock().expect("name mutex").take() {
                let _ = tx.send(name);
            }
            echo(channel, closed)
        });
        let accept = accept_messages(&server);
        let client = ChannelClient::new(&client_transport);

        let mut channel = client
            .connect(&server.endpoint().addr(), "control")
            .await
            .expect("connect");
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), name_rx)
                .await
                .expect("handler saw the channel name")
                .expect("name sent"),
            "control"
        );

        channel
            .send(Message::Text("sz,640,480"))
            .await
            .expect("send text");
        assert_eq!(
            channel.recv().await.expect("recv").expect("message"),
            Received::Text("sz,640,480".into())
        );

        // More than the default 1.25 MB stream window: the channel must carry
        // it without a separate HTTP or WS layer re-chunking.
        let payload = Bytes::from(vec![7u8; 2 * 1024 * 1024]);
        channel
            .send(Message::Binary(&payload))
            .await
            .expect("send binary");
        assert_eq!(
            channel.recv().await.expect("recv").expect("message"),
            Received::Binary(payload)
        );

        channel.close();
        tokio::time::timeout(Duration::from_secs(5), closed_rx)
            .await
            .expect("server saw the close")
            .expect("handler signalled");

        accept.abort();
        server.endpoint().close().await;
        client_transport.endpoint().close().await;
    }

    /// Percentiles for `count` round trips of `size` bytes over a WebSocket
    /// (the `idfon-h1` path: HTTP/1.1 + RFC 6455).
    async fn measure_ws<S, E>(label: &str, socket: &mut S, size: usize, count: usize)
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
            socket.send(Message::Binary(frame.clone())).await.expect("send");
            match socket.next().await.expect("echo").expect("echo ok") {
                Message::Binary(data) => assert_eq!(data.len(), size),
                other => panic!("unexpected message: {other:?}"),
            }
            samples.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        report(label, &mut samples);
    }

    /// Same measurement over a raw channel (no HTTP, no RFC 6455).
    async fn measure_channel(label: &str, channel: &mut Channel, size: usize, count: usize) {
        let frame = vec![0xa5u8; size];
        let mut samples = Vec::with_capacity(count);
        for _ in 0..count {
            let started = std::time::Instant::now();
            channel.send(Message::Binary(&frame)).await.expect("send");
            match channel.recv().await.expect("recv").expect("echo") {
                Received::Binary(data) => assert_eq!(data.len(), size),
                other => panic!("unexpected message: {other:?}"),
            }
            samples.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        report(label, &mut samples);
    }

    fn report(label: &str, samples: &mut [f64]) {
        samples.sort_by(|a, b| a.partial_cmp(b).expect("finite"));
        let count = samples.len();
        let p50 = samples[count / 2];
        let p95 = samples[(count * 95 / 100).min(count - 1)];
        eprintln!(
            "MEASURE {label}: round trip p50 {p50:.3} ms, p95 {p95:.3} ms, max {:.3} ms",
            samples[count - 1]
        );
    }

    /// The only fair A/B for "drop the WS layer": same transport, same path,
    /// same payloads, same code minus HTTP/1.1 + RFC 6455. The static cost of
    /// the framing itself is printed with the samples — it is not a network
    /// measurement, it is the layer's per-message price.
    ///
    /// `cargo test -p idfon-channel -- --ignored --nocapture overhead`
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "per-message overhead bench: WS over h1 vs raw channel"]
    async fn ws_layer_vs_raw_channel_overhead() {
        use axum::{
            extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade},
            routing::get,
            Router,
        };
        use futures_util::{SinkExt, StreamExt};
        use idfon_h1::H1Client;
        use tokio_tungstenite::{
            tungstenite::{protocol::Role, Message as SocketMessage},
            WebSocketStream,
        };

        const RAW_WS_ALPN: &[u8] = b"idfon/h1bench/ws";

        let (server, client_transport) = pair().await;
        let _channels = serve_channels(&server, |_peer, _name, channel| {
            echo(channel, Arc::new(std::sync::Mutex::new(None)))
        });
        // RFC 6455 straight onto an iroh bi-stream: no hyper, no axum writer
        // task. Isolates the codec from the HTTP/axum adapter.
        let (ws_tx, mut ws_rx) = mpsc::channel(8);
        let _raw_ws_guard = server.add_side_channel(RAW_WS_ALPN, ws_tx);
        tokio::spawn(async move {
            while let Some(connection) = ws_rx.recv().await {
                tokio::spawn(async move {
                    if let Ok((send, recv)) = connection.accept_bi().await {
                        let io = tokio::io::join(recv, send);
                        if let Ok(mut socket) = tokio_tungstenite::accept_async(io).await {
                            while let Some(Ok(message)) = socket.next().await {
                                if socket.send(message).await.is_err() {
                                    break;
                                }
                            }
                        }
                    }
                    connection.closed().await;
                });
            }
        });
        let _h1 = idfon_h1::serve_router(
            &server,
            Router::new().route(
                "/ws",
                get(|upgrade: WebSocketUpgrade| async move {
                    upgrade.on_upgrade(|mut socket: WebSocket| async move {
                        while let Some(Ok(message)) = socket.recv().await {
                            if socket.send(message).await.is_err() {
                                break;
                            }
                        }
                    })
                }),
            ),
        );
        let accept = accept_messages(&server);
        let addr = server.endpoint().addr();
        // Dial the bound port explicitly: advertised addresses on a VPN host
        // resolve to the relay, which measures the relay instead. With
        // `IDFON_RELAY_ONLY=1` that *is* the point: a real network path.
        let relay_only = std::env::var("IDFON_RELAY_ONLY")
            .is_ok_and(|value| matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes"));
        let bound = match server.endpoint().bound_sockets().first() {
            Some(_) if !relay_only => server.endpoint().bound_sockets().first().map(|socket| socket.port()),
            _ => None,
        };
        let target = match bound {
            Some(port) => EndpointAddr::from_parts(
                addr.id,
                [iroh::TransportAddr::Ip(
                    (std::net::Ipv4Addr::LOCALHOST, port).into(),
                )],
            ),
            None => addr.clone(),
        };
        eprintln!("PATH {}: {:?}", if relay_only { "relay-only" } else { "direct loopback" }, target);
        eprintln!(
            "OVERHEAD per message: RFC 6455 = 4 B (1 KiB) / 10 B (64 KiB); raw channel = 5 B"
        );

        // WebSocket over h1 (the current path).
        let h1_client = H1Client::new(&client_transport);
        let mut connection = h1_client.connect(&target).await.expect("h1 connect");
        let request = http::Request::builder()
            .method(http::Method::GET)
            .uri("/ws")
            .header("connection", "upgrade")
            .header("upgrade", "websocket")
            .header("sec-websocket-version", "13")
            .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
            .body(axum::body::Body::empty())
            .expect("ws request");
        let response = connection.send(request).await.expect("ws handshake");
        assert_eq!(response.status(), http::StatusCode::SWITCHING_PROTOCOLS);
        let io = idfon_h1::upgrade(response).await.expect("upgrade");
        let mut ws = WebSocketStream::from_raw_socket(io, Role::Client, None).await;
        measure_ws("web  (ws over h1) 1 KiB ", &mut ws, 1024, 200).await;
        measure_ws("web  (ws over h1) 64 KiB", &mut ws, 64 * 1024, 100).await;
        ws.send(SocketMessage::Close(None)).await.expect("close");
        drop(connection);

        // RFC 6455 on a raw iroh stream (no HTTP, no axum).
        let (raw_ws_connection, raw_send, raw_recv) = client_transport
            .open_bi_stream(&target, RAW_WS_ALPN)
            .await
            .expect("raw ws dial");
        let (mut raw_ws, _) =
            tokio_tungstenite::client_async("ws://idfon/ws", tokio::io::join(raw_recv, raw_send))
                .await
                .expect("raw ws handshake");
        measure_ws("ws   (no http)      1 KiB ", &mut raw_ws, 1024, 200).await;
        measure_ws("ws   (no http)      64 KiB", &mut raw_ws, 64 * 1024, 100).await;
        raw_ws
            .send(SocketMessage::Close(None))
            .await
            .expect("raw ws close");
        drop(raw_ws_connection);

        // Raw channel, everything else identical.
        let mut channel = ChannelClient::new(&client_transport)
            .connect(&target, "bench")
            .await
            .expect("channel connect");
        measure_channel("raw  (channel)     1 KiB ", &mut channel, 1024, 200).await;
        measure_channel("raw  (channel)     64 KiB", &mut channel, 64 * 1024, 100).await;
        channel.close();

        accept.abort();
        server.endpoint().close().await;
        client_transport.endpoint().close().await;
        let _ = WsMessage::Close(None);
    }

    /// A name over [`MAX_CHANNEL_NAME`] is rejected before the handler runs: a
    /// peer must not be able to hand the server an arbitrarily large label.
    #[tokio::test]
    async fn oversized_channel_name_is_rejected() {
        let (server, client_transport) = pair().await;
        let (opened_tx, opened_rx) = oneshot::channel::<()>();
        let opened_tx = Arc::new(std::sync::Mutex::new(Some(opened_tx)));

        let _server = serve_channels(&server, move |_peer, _name, channel| {
            let opened = Arc::clone(&opened_tx);
            async move {
                if let Some(tx) = opened.lock().expect("opened mutex").take() {
                    let _ = tx.send(());
                }
                echo(channel, Arc::new(std::sync::Mutex::new(None))).await;
            }
        });
        let accept = accept_messages(&server);
        let client = ChannelClient::new(&client_transport);

        let name = "x".repeat(MAX_CHANNEL_NAME + 1);
        let mut channel = client
            .connect(&server.endpoint().addr(), &name)
            .await
            .expect("the dial itself succeeds; the server decides on the name");
        assert!(
            tokio::time::timeout(Duration::from_secs(3), channel.recv())
                .await
                .expect("server responded")
                .map_or(true, |message| message.is_none()),
            "an oversized name must not reach the handler"
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(200), opened_rx)
                .await
                .is_err(),
            "the handler must never run for a rejected name"
        );

        accept.abort();
        server.endpoint().close().await;
        client_transport.endpoint().close().await;
    }

    /// Sharding: a channel whose consumer stops draining must not stall another
    /// channel. One connection per channel is the isolation boundary.
    #[tokio::test]
    async fn a_stalled_channel_does_not_stall_another_channel() {
        let (server, client_transport) = pair().await;
        let (flood_done_tx, mut flood_done_rx) = oneshot::channel::<()>();
        let flood_done_tx = Arc::new(std::sync::Mutex::new(Some(flood_done_tx)));

        let _server = serve_channels(&server, move |_peer, name, mut channel| {
            let done = Arc::clone(&flood_done_tx);
            async move {
                match name.as_str() {
                    // 16 MiB is well past the default QUIC stream window, so
                    // this blocks once the peer stops reading.
                    "video" => {
                        for _ in 0..256 {
                            if channel.send(Message::Binary(&[0u8; 64 * 1024])).await.is_err() {
                                break;
                            }
                        }
                        if let Some(tx) = done.lock().expect("flood mutex").take() {
                            let _ = tx.send(());
                        }
                    }
                    _ => echo(channel, Arc::new(std::sync::Mutex::new(None))).await,
                }
            }
        });
        let accept = accept_messages(&server);
        let addr = server.endpoint().addr();
        let client = ChannelClient::new(&client_transport);

        // `video` subscriber that never reads.
        let stalled = client.connect(&addr, "video").await.expect("video channel");
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(
            tokio::time::timeout(Duration::from_millis(250), &mut flood_done_rx)
                .await
                .is_err(),
            "the video channel should be blocked on flow control with no reader"
        );

        // `control` is a separate connection and stays responsive.
        let mut control = tokio::time::timeout(
            Duration::from_secs(10),
            client.connect(&addr, "control"),
        )
        .await
        .expect("a second channel must not wait behind the stalled one")
        .expect("control channel");
        control
            .send(Message::Text("ping"))
            .await
            .expect("control send");
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), control.recv())
                .await
                .expect("control reply must not wait behind video")
                .expect("control recv")
                .expect("control message"),
            Received::Text("ping".into())
        );

        // Dropping the stalled peer unblocks and tears its handler down.
        drop(stalled);
        tokio::time::timeout(Duration::from_secs(5), flood_done_rx)
            .await
            .expect("stalled channel tears down when the peer goes away")
            .expect("flood handler signalled");

        accept.abort();
        server.endpoint().close().await;
        client_transport.endpoint().close().await;
    }
}
