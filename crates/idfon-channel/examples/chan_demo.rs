//! Two-host benchmark and smoke test for `idfon-channel`.
//!
//! ```sh
//! # host A (prints the ticket; echoes every channel)
//! cargo run --release -p idfon-channel --example chan_demo -- serve
//! # host B, with the TICKET line printed by A
//! cargo run --release -p idfon-channel --example chan_demo -- bench --peer '<ticket>'
//!
//! # same shape for the WS arm, to compare on the same link:
//! cargo run --release -p idfon-h1 --example h1_demo -- serve       # host A
//! cargo run --release -p idfon-h1 --example h1_demo -- ws --peer '<ticket>'  # host B
//! ```
//!
//! The ticket is the peer's `EndpointAddr` (endpoint id + addresses): no port,
//! certificate, or token. Run both hosts on the same LAN, or on two networks to
//! get a direct-P2P row; `IDFON_RELAY_ONLY=1` on both forces the relay instead.

use std::{sync::Arc, time::Duration};

use idfon_channel::{serve_channels, ChannelClient, Message, Received};
use idfon_core::transport::{IrohTransport, TransportError};
use idfon_protocol::MessageAck;
use iroh::EndpointAddr;

type Error = Box<dyn std::error::Error>;

#[tokio::main]
async fn main() -> Result<(), Error> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("serve") => serve().await,
        Some("bench") => {
            let mut peer = None;
            let mut size = None;
            let mut count = None;
            while let Some(flag) = args.next() {
                let value = args.next().ok_or(format!("{flag} needs a value"))?;
                match flag.as_str() {
                    "--peer" => peer = Some(serde_json::from_str::<EndpointAddr>(&value)?),
                    "--size" => size = Some(value.parse::<usize>()?),
                    "--count" => count = Some(value.parse::<usize>()?),
                    other => return Err(format!("unexpected argument {other}").into()),
                }
            }
            bench(
                &peer.ok_or("--peer <EndpointAddr JSON> is required")?,
                size,
                count,
            )
            .await
        }
        _ => {
            eprintln!("usage: chan_demo serve | bench --peer <EndpointAddr JSON> [--size N] [--count N]");
            std::process::exit(2);
        }
    }
}

async fn serve() -> Result<(), Error> {
    let transport = Arc::new(IrohTransport::bind().await?);
    let addr = transport.endpoint().addr();
    println!("TICKET {}", serde_json::to_string(&addr)?);

    // Both arms on one identity: WS over h1 (`/ws`) and channels, so a
    // two-host run compares them on the same link.
    let app = axum::Router::new().route(
        "/ws",
        axum::routing::get(|upgrade: axum::extract::ws::WebSocketUpgrade| async move {
            upgrade.on_upgrade(|mut socket: axum::extract::ws::WebSocket| async move {
                while let Some(Ok(message)) = socket.recv().await {
                    if socket.send(message).await.is_err() {
                        break;
                    }
                }
            })
        }),
    );
    let _h1 = idfon_h1::serve_router(&transport, app);

    let _channels = serve_channels(&transport, |peer, name, mut channel| async move {
        eprintln!("channel {name} from {peer}");
        while let Ok(Some(message)) = channel.recv().await {
            let sent = match message {
                Received::Text(text) => channel.send(Message::Text(&text)).await,
                Received::Binary(data) => channel.send(Message::Binary(&data)).await,
            };
            if sent.is_err() {
                break;
            }
        }
    });
    // Side-channel ALPNs are dispatched from the message accept loop.
    let _ = transport
        .serve(|_| async {
            Err::<MessageAck, TransportError>(TransportError::Failed("unused".into()))
        })
        .await;
    Ok(())
}

async fn bench(peer: &EndpointAddr, size: Option<usize>, count: Option<usize>) -> Result<(), Error> {
    let transport = Arc::new(IrohTransport::bind().await?);
    let sizes: Vec<usize> = match size {
        Some(size) => vec![size],
        None => vec![1024, 64 * 1024],
    };
    let count = count.unwrap_or(200);

    // The first connection to a peer often starts on the relay while
    // hole-punching settles, and a connection does not migrate afterwards — so
    // the first arm would measure the relay and the second the punched path.
    // Wait for a direct path on a throwaway connection first.
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let (probe, _, _) = transport.open_bi_stream(peer, idfon_channel::ALPN).await?;
        let direct = probe.paths().iter().any(|path| path.is_ip());
        eprintln!("PATH direct={direct}");
        probe.close(0u32.into(), b"probe");
        if direct || std::time::Instant::now() > deadline {
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    const WARMUP: usize = 20;

    let client = ChannelClient::new(&transport);
    // Two rounds on fresh connections: round 1 carries the connection's own
    // warm-up (and any path switch), round 2 is the comparison.
    for round in 1..=2 {
        let mut channel = client.connect(peer, "bench").await?;
        for _ in 0..WARMUP {
            channel.send(Message::Binary(&[0u8; 1024])).await?;
            let _ = channel.recv().await?;
        }
        for size in &sizes {
            measure_channel(round, &mut channel, *size, count).await?;
        }
        channel.close();
    }

    let h1 = idfon_h1::H1Client::new(&transport);
    for round in 1..=2 {
    let mut connection = h1.connect(peer).await?;
    let request = http::Request::builder()
        .method(http::Method::GET)
        .uri("/ws")
        .header("connection", "upgrade")
        .header("upgrade", "websocket")
        .header("sec-websocket-version", "13")
        .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        .body(axum::body::Body::empty())?;
    let response = connection.send(request).await?;
    let io = idfon_h1::upgrade(response).await?;
    let mut ws = tokio_tungstenite::WebSocketStream::from_raw_socket(
        io,
        tokio_tungstenite::tungstenite::protocol::Role::Client,
        None,
    )
    .await;
    for _ in 0..WARMUP {
        ws_send_recv(&mut ws, 1024).await?;
    }
    for size in &sizes {
        measure_ws(round, &mut ws, *size, count).await?;
    }
    }

    let _ = tokio::time::timeout(Duration::from_secs(2), transport.endpoint().close()).await;
    Ok(())
}

fn percentile(samples: &mut [f64]) -> (f64, f64, f64) {
    samples.sort_by(|a, b| a.partial_cmp(b).expect("finite"));
    let count = samples.len();
    (
        samples[count / 2],
        samples[(count * 95 / 100).min(count - 1)],
        samples[count - 1],
    )
}

async fn measure_channel(
    round: usize,
    channel: &mut idfon_channel::Channel,
    size: usize,
    count: usize,
) -> Result<(), Error> {
    let frame = vec![0xa5u8; size];
    let mut samples = Vec::with_capacity(count);
    for _ in 0..count {
        let started = std::time::Instant::now();
        channel.send(Message::Binary(&frame)).await?;
        match channel.recv().await? {
            Some(Received::Binary(data)) => assert_eq!(data.len(), size),
            other => return Err(format!("unexpected message: {other:?}").into()),
        }
        samples.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    let (p50, p95, max) = percentile(&mut samples);
    println!(
        "MEASURE r{round} channel {size:>6} B x{count}: p50 {p50:.3} ms, p95 {p95:.3} ms, max {max:.3} ms"
    );
    Ok(())
}

async fn ws_send_recv<S, E>(ws: &mut S, size: usize) -> Result<(), Error>
where
    S: futures_util::Sink<tokio_tungstenite::tungstenite::Message, Error = E>
        + futures_util::Stream<
            Item = Result<tokio_tungstenite::tungstenite::Message, E>,
        > + Unpin,
    E: std::fmt::Debug + std::fmt::Display,
{
    use futures_util::StreamExt;
    use tokio_tungstenite::tungstenite::Message as SocketMessage;
    use futures_util::SinkExt as _;
    ws.send(SocketMessage::Binary(vec![0xa5; size].into()))
        .await
        .map_err(|error| format!("ws send: {error}"))?;
    let next = ws
        .next()
        .await
        .ok_or("ws closed")?
        .map_err(|error| format!("ws recv: {error}"))?;
    match next {
        SocketMessage::Binary(data) => assert_eq!(data.len(), size),
        other => return Err(format!("unexpected message: {other:?}").into()),
    }
    Ok(())
}

async fn measure_ws<S, E>(round: usize, ws: &mut S, size: usize, count: usize) -> Result<(), Error>
where
    S: futures_util::Sink<tokio_tungstenite::tungstenite::Message, Error = E>
        + futures_util::Stream<
            Item = Result<tokio_tungstenite::tungstenite::Message, E>,
        > + Unpin,
    E: std::fmt::Debug + std::fmt::Display,
{
    let mut samples = Vec::with_capacity(count);
    for _ in 0..count {
        let started = std::time::Instant::now();
        ws_send_recv(ws, size).await?;
        samples.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    let (p50, p95, max) = percentile(&mut samples);
    println!(
        "MEASURE r{round} ws      {size:>6} B x{count}: p50 {p50:.3} ms, p95 {p95:.3} ms, max {max:.3} ms"
    );
    Ok(())
}

