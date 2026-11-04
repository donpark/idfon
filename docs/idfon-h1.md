# idfon-h1: HTTP/1.1 over iroh

Serve an **existing [`axum::Router`]** to idfon peers with real HTTP/1.1, so
handlers that already stream keep working unmodified: `WebSocketUpgrade`, SSE,
chunked bodies, plain request/response. Streaming sibling of the h3 path
(`idfon-h3` serves request/response; h1 adds the streaming half).

Status: **current** for slices 1–2 of [#142] (server + client, tested). The
voxl demo (slice 3) and channel sharding (slice 4) are not in this crate.

[#142]: https://github.com/donpark/idfon/issues/142

## Why it is cheap

No new protocol and no custom WS codec: a QUIC bi-stream is bridged to hyper's
HTTP/1.1 server, and `.with_upgrades()` hands the byte stream to whatever speaks
RFC 6455 on top. `axum::extract::ws::WebSocketUpgrade` therefore works as-is,
`axum::response::Sse` needs nothing extra, and any WS library that accepts a
byte stream works on the client side.

There is also no TLS, no `Host`/`Origin` check and no token on this path. There
is no browser to satisfy, and the QUIC handshake already proves who dialed: the
dialing [`EndpointId`] is the identity.

## Shape

```text
peer ── iroh connection (ALPN idfon/http1/1) ── one bi-stream
                                                   │
                          tokio::io::join(recv, send) + TokioIo
                                                   │
        hyper http1::serve_connection(io, router).with_upgrades()
```

- `ALPN = b"idfon/http1/1"`; it coexists on one endpoint/identity with
  `idfon/http3/1` and `idfon/message/1` (the accept loop dispatches by ALPN).
- [`idfon_h1::serve_router(&Arc<IrohTransport>, Router)`] registers the ALPN and
  serves each accepted connection. Run it next to `IrohTransport::serve` — that
  loop is what dispatches side channels, so nothing is accepted without it.
- [`RemoteId`] (`idfon_h1::RemoteId(pub EndpointId)`) is inserted into request
  extensions for that connection; handlers extract it like any other axum
  extractor. Same job as `idfon_h3::RemoteId`.
- Client: [`H1Client`] dials by [`EndpointAddr`]. `get`/`fetch` are one-shot
  (dial, send, collect, close); `connect` returns an `H1Connection` for
  streaming responses and WebSocket upgrades. [`upgrade`] resolves the
  `Upgraded` byte stream of a `101`, wrapped for tokio.

```rust,ignore
// server
let h1 = idfon_h1::serve_router(&transport, app);

// client: one-shot GET
let response = idfon_h1::H1Client::new(&transport)
    .get(&peer_addr, "/screenshot")
    .await?;

// client: WebSocket
let mut connection = client.connect(&peer_addr).await?;
let response = connection
    .send(Request::get("/ws")
        .header("connection", "upgrade")
        .header("upgrade", "websocket")
        .header("sec-websocket-version", "13")
        .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        .body(Body::empty())?)
    .await?;
let io = idfon_h1::upgrade(response).await?;
let mut socket = tokio_tungstenite::WebSocketStream::from_raw_socket(
    io, Role::Client, None,
).await;
```

`idfon_h1::uri(peer_id, "/path")` builds the display form
`iroh+h1://<endpoint-id>/path` (the scheme is nominal; the authority selects the
peer).

## Semantics and limits

- **No multiplexing.** One iroh connection carries one HTTP/1.1 connection; one
  request at a time; a WebSocket session owns its connection for its lifetime.
  Parallel requests mean parallel connections. Multiplexed request/response is
  what the h3 path is for.
- **Upgrade lifetime.** hyper's connection future returns while the upgraded
  stream is still live, so the server must not close the QUIC connection after a
  `101`. The code relies on the upgraded stream's own handle: the connection
  closes when the last stream goes away.
- **Limits.** hyper's defaults bound the request line + headers (400 KiB
  buffer, 100 headers). axum's `DefaultBodyLimit` (2 MB) applies to request
  bodies as usual; disable it per route for uploads.
- **Client teardown.** `H1Connection` aborts its driver task on drop, which drops
  the stream and closes the connection — keep it alive while reading a streaming
  body.
- Clients that need many concurrent requests on one connection should use
  `idfon-h3`.

`shortcut:` HTTP/1.1 only — no HTTP/2, no TLS, no content negotiation.

## Measured

Functional suite (`cargo test -p idfon-h1`): plain GET with `RemoteId`;
keep-alive (two sequential requests on one connection); chunked (request streamed
without `Content-Length`); SSE that streams event-by-event and tears its handler
stream down when the reader disappears; WS echo with a 2 MiB binary payload
(> one QUIC stream window), clean close, and a **stock tungstenite client** doing
the RFC 6455 handshake itself over a raw bi-stream (no idfon-h1 client code); and
h1 + h3 + message ALPN on one endpoint.

Throughput (`cargo test -p idfon-h1 -- --ignored --nocapture throughput`), on a
**direct** QUIC path over loopback, 12 MiB each way:

| path | download | upload |
| --- | --- | --- |
| h1 | ~200–270 Mbps | ~255–290 Mbps |
| h3 (reference) | ~270–330 Mbps | — |

These are loopback numbers, not a LAN bench. The same test dialed through the
advertised addresses on this host lands on the **relay** path (VPN-assigned
interfaces), where both h1 and h3 sit at ~10 Mbps — i.e. relay-bound, not
adapter-bound. The LAN / 1% loss / voxl 55 fps acceptance in [#142] still needs
the demo machine.

## Using it with an existing app (voxl recipe)

`~/dev/tests/voxl` is a separate repo; nothing there is changed by this crate.
The recipe:

1. voxl's server is a plain `axum::Router` with state (`src/server.rs:151-167`);
   media producers only touch `hub::Out` (`src/hub.rs:18`), so they never see the
   transport. Add an `--iroh` mode that binds an `IrohTransport`, calls
   `idfon_h1::serve_router(&transport, app)`, runs `transport.serve(...)` for the
   message path, and prints `idfon_h1::uri(transport.endpoint().id(), "/")`
   instead of the `http://…?token=` URL.
2. Cheapest demo: poll `/screenshot` (`src/record.rs:93`, on-demand PNG) with
   `H1Client::get` at 10–15 fps — no new client code. `/files/*` upload and
   download work through the same client (`fetch` with a `Body`).
3. Then 60 fps: a Rust `/ws` client that sends the standard upgrade headers,
   calls `idfon_h1::upgrade`, wraps the stream in
   `WebSocketStream::from_raw_socket`, and speaks `web/src/protocol.ts`
   verbatim (text CSV commands + binary messages with a type byte).

Two caveats belong to the demo, not this crate:

- A WS session owns one QUIC stream, so today's TCP-style head-of-line remains.
  Channel sharding over separate connections is [#142] slice 4, where the perf
  win lives; measure before/after, do not assume.
- voxl must extract `handle_message` + `READ_ONLY_COMMANDS` out of
  `handle_socket` **before** a second carrier exists, or the iroh path silently
  bypasses read-only mode.

## Tests

```sh
cargo test -p idfon-h1
cargo test -p idfon-h1 -- --ignored --nocapture throughput
```

The tests use two real `IrohTransport`s and a unique key per test: iroh routes
by endpoint id, so shared keys let one test dial another test's server.

## Rebuild scope

Library-only: nothing to rebuild. Once a binary starts calling `serve_router`:
`crates/idfond`/CLI (`pnpm cli build`), the edge image (`deploy/idfon-edge`), or
the eve agents (`pnpm eve build`) depending on which one wires it up. The apps
link the feature core through `libiroh_c_ffi`, so they only need rebuilding if
the h1 path is exposed through the daemon/FFI — today it is not. See
`build.md`.
