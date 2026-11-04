//! Manual smoke test for `idfon-h1`, across two processes (or two machines).
//!
//! ```sh
//! # machine A
//! cargo run -p idfon-h1 --example h1_demo -- serve
//! # machine B, with the TICKET line printed by A
//! cargo run -p idfon-h1 --example h1_demo -- get --peer '<ticket>' --path /whoami
//! cargo run -p idfon-h1 --example h1_demo -- get --peer '<ticket>' --path /sse
//! cargo run -p idfon-h1 --example h1_demo -- ws  --peer '<ticket>'
//! ```
//!
//! No port, no certificate, no token: the ticket is the peer's `EndpointAddr`
//! (endpoint id + addresses). The example runs the message accept loop only
//! because side-channel ALPNs are dispatched there; a real embedder would run
//! its normal message handler instead.

use std::{sync::Arc, time::Duration};

use axum::{
    extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade},
    response::sse::{Event, Sse},
    routing::get,
    Router,
};
use futures_util::{stream, StreamExt};
use idfon_core::transport::{IrohTransport, TransportError};
use idfon_h1::{serve_router, upgrade, H1Client, RemoteId};
use idfon_protocol::MessageAck;
use iroh::EndpointAddr;

type Error = Box<dyn std::error::Error>;

#[tokio::main]
async fn main() -> Result<(), Error> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("serve") => serve().await,
        Some(mode @ ("get" | "ws")) => {
            let peer = parse_peer(&mut args)?;
            let path = parse_path(&mut args)?;
            if mode == "get" {
                fetch(&peer, &path).await
            } else {
                converse(&peer, &path).await
            }
        }
        _ => {
            eprintln!("usage: h1_demo serve | get|ws --peer <EndpointAddr JSON> [--path /path]");
            std::process::exit(2);
        }
    }
}

fn parse_peer(args: &mut impl Iterator<Item = String>) -> Result<EndpointAddr, Error> {
    match args.next().as_deref() {
        Some("--peer") => Ok(serde_json::from_str(
            &args.next().ok_or("--peer needs a value")?,
        )?),
        _ => Err("--peer <EndpointAddr JSON> is required".into()),
    }
}

fn parse_path(args: &mut impl Iterator<Item = String>) -> Result<String, Error> {
    match args.next().as_deref() {
        Some("--path") => Ok(args.next().ok_or("--path needs a value")?),
        None => Ok("/".into()),
        Some(other) => Err(format!("unexpected argument {other}").into()),
    }
}

async fn serve() -> Result<(), Error> {
    let transport = Arc::new(IrohTransport::bind().await?);
    let addr = transport.endpoint().addr();
    println!("TICKET {}", serde_json::to_string(&addr)?);
    println!("iroh address: {}", idfon_h1::uri(addr.id, "/"));

    let app = Router::new()
        .route("/", get(|| async { "hello over idfon/http1/1" }))
        .route(
            "/whoami",
            get(|RemoteId(peer): RemoteId| async move { peer.to_string() }),
        )
        .route(
            "/sse",
            get(|| async {
                // Three events, one per second, to show streaming rather than
                // a buffered body.
                let events = stream::unfold(0, |tick| async move {
                    if tick == 3 {
                        return None;
                    }
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    Some((
                        Ok::<_, std::io::Error>(Event::default().data(format!("tick {tick}"))),
                        tick + 1,
                    ))
                });
                Sse::new(events)
            }),
        )
        .route(
            "/ws",
            get(|ws: WebSocketUpgrade| async move { ws.on_upgrade(echo) }),
        );

    let _h1 = serve_router(&transport, app);
    let accept = Arc::clone(&transport);
    tokio::spawn(async move {
        let _ = accept
            .serve(|_| async {
                Err::<MessageAck, TransportError>(TransportError::Failed(
                    "message path unused by this example".into(),
                ))
            })
            .await;
    });

    println!("serving on idfon/http1/1 — ctrl-c to stop");
    tokio::signal::ctrl_c().await?;
    Ok(())
}

async fn fetch(peer: &EndpointAddr, path: &str) -> Result<(), Error> {
    let transport = Arc::new(IrohTransport::bind().await?);
    let started = std::time::Instant::now();
    let response = H1Client::new(&transport).get(peer, path).await?;
    let elapsed = started.elapsed();
    println!(
        "{} in {:?} — {} bytes",
        response.status(),
        elapsed,
        response.body().len()
    );
    println!("{}", String::from_utf8_lossy(response.body()));
    transport.endpoint().close().await;
    Ok(())
}

async fn converse(peer: &EndpointAddr, path: &str) -> Result<(), Error> {
    use futures_util::SinkExt;
    use tokio_tungstenite::{
        tungstenite::{protocol::Role, Message},
        WebSocketStream,
    };

    let transport = Arc::new(IrohTransport::bind().await?);
    let client = H1Client::new(&transport);
    let mut connection = client.connect(peer).await?;
    let request = http::Request::get(path)
        .header("connection", "upgrade")
        .header("upgrade", "websocket")
        .header("sec-websocket-version", "13")
        .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        .body(axum::body::Body::empty())?;
    let response = connection.send(request).await?;
    println!("handshake: {}", response.status());
    let io = upgrade(response).await?;
    let mut socket = WebSocketStream::from_raw_socket(io, Role::Client, None).await;

    for text in ["ping", "second"] {
        socket.send(Message::Text(text.into())).await?;
        match socket.next().await {
            Some(Ok(Message::Text(reply))) => println!("sent {text} -> {reply}"),
            other => println!("unexpected reply: {other:?}"),
        }
    }
    socket.close(None).await?;
    transport.endpoint().close().await;
    Ok(())
}

async fn echo(mut socket: WebSocket) {
    while let Some(Ok(message)) = socket.recv().await {
        let reply = match message {
            WsMessage::Text(text) => WsMessage::Text(text),
            WsMessage::Binary(data) => WsMessage::Binary(data),
            WsMessage::Close(_) => break,
            _ => continue,
        };
        if socket.send(reply).await.is_err() {
            break;
        }
    }
}
