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

## Sibling: no-HTTP channels

When both ends are ours and the HTTP shape buys nothing, `idfon-channel`
(`docs/idfon-channel.md`, issue [#142]) carries the same WebSocket-style
send/recv API on a bare iroh bi-stream — one ordered reliable stream per
channel, `[kind][len][payload]` framing, channel-name sharding, no hyper. Use
it for per-channel isolation inside one app; use h1 whenever an existing
`axum::Router`, a third-party developer's WS server, or a language's stock WS
library is the point. Measured side by side (loopback, relay, and Wi-Fi
two-host), the two are within noise of each other: the layer is not the cost,
the path is.



Functional suite (`cargo test -p idfon-h1`): plain GET with `RemoteId`;
keep-alive (two sequential requests on one connection); chunked (request streamed
without `Content-Length`); SSE that streams event-by-event and tears its handler
stream down when the reader disappears; WS echo with a 2 MiB binary payload
(> one QUIC stream window), clean close, and a **stock tungstenite client** doing
the RFC 6455 handshake itself over a raw bi-stream (no idfon-h1 client code); and
h1 + h3 + message ALPN on one endpoint.

### What the numbers actually support

Exactly **one** row here is a real-network measurement, and it is the relay:

| path | status | throughput | frame p95 |
| --- | --- | --- | --- |
| public N0 relay (internet) | measured | ~10 Mbps | ~53 ms (1 KiB), ~142 ms (64 KiB) |
| direct P2P over the internet | **not measured** | unknown | unknown |
| LAN, two hosts | **not measured** | unknown | unknown |
| loopback, any transport | diagnostic only | see below | see below |

The measured internet ceiling for this crate is **~10 Mbps through the N0
relay** — 64 KiB frames at ~7 fps, or ~20 KiB/frame at 60 fps. That is a *relay*
number: it may be the free relay's per-connection limit, this host's VPN egress,
or the path to `usw1-1`, and one measurement cannot separate them. A
self-hosted relay (`IDFON_RELAY_URLS`) and a second host would.

A **direct** peer-to-peer path over the internet is not measured at all. Its
ceiling is bounded above by the stack's own ~410 Mbps on loopback and below by
the slower uplink of the two peers; where it lands is the missing experiment.

Loopback rows are diagnostics, never network results:

- **h1 vs a raw `pump` on loopback.** Same bytes, no HTTP, no network — the delta
  is the adapter's cost, and it is ~0 (48 vs 40 MiB/s per direction). When h1 is
  slow, iroh is slow.
- **Loopback is a kernel fast path with no wire.** TCP moves ~3,900 MiB/s there
  because loopback is a memcpy with GSO/GRO and no NIC; iroh moves ~48–51 MiB/s
  because userspace QUIC pays a syscall, a crypto op and a pacing decision per
  datagram. Comparing the two on loopback measures kernel shortcuts, not either
  protocol on a network — which is why that comparison is not in the table above.

**Harness note.** Earlier numbers on this page were taken on a single-threaded
`#[tokio::test]` runtime (both endpoints, their QUIC stacks, hyper and the test
sharing one core), which halved the loopback figures (27 → 48 MiB/s). The relay
row was unchanged across runtime sizes, consistent with it being network-bound.

### Adapter ceiling (why the loopback row is not a network number)

`iroh` is the transport (QUIC over UDP, userspace, with hole-punching and relay
fallback). `hyper` is the Rust HTTP engine: it parses the HTTP/1.1 request,
handles `Connection: Upgrade`, and hands back a raw byte stream after the `101`.
The "adapter" is the ~200 lines in this crate that joins the two — iroh's
`SendStream`/`RecvStream` become hyper's IO, and hyper's upgraded connection
becomes the WebSocket. "Adapter ceiling" was my loose term for: both endpoints
on one machine, so the only costs in the number are iroh's packet handling and
hyper's parsing. It is the best case for the adapter and says nothing about
Wi-Fi, congestion, or distance — which is why the relay row exists.

### Raw numbers behind the rows

`cargo test -p idfon-h1 -- --ignored --nocapture throughput`, 12 MiB each way,
four worker threads, with the selected path printed by the bench itself.

Loopback — the stack's ceiling, **not** a network number:

| path | download | upload | 1 KiB WS p95 | 64 KiB WS p95 |
| --- | --- | --- | --- | --- |
| direct, loopback QUIC | ~404 Mbps | ~427 Mbps | ~0.24 ms | ~2.6–2.9 ms |
| raw iroh pump, no HTTP | ~343 Mbps | — | — | — |

Relay — the one real-network row (`IDFON_RELAY_ONLY=1`, the knob the apps honor:
`idfon-core` clears IP transports, so only the relay address is published):

| path | download | upload | 1 KiB WS p95 | 64 KiB WS p95 |
| --- | --- | --- | --- | --- |
| public N0 relay | ~10 Mbps | ~10 Mbps | ~53 ms | ~142 ms |

h3 tracks h1 on both (422 Mbps loopback, 8 Mbps relay). Stop-and-wait ceilings
from the p95s: ~4,200 fps (1 KiB) and ~350–360 fps (64 KiB) on loopback,
~19 fps and ~7 fps on the relay. A pipelined sender is bandwidth-bound instead:
~830 KiB/frame at 60 fps on loopback, ~20 KiB/frame on the relay.

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

There is a working precedent for step 1 in voxl itself, on the local branch
`idfon-h1-test`: `server::tests::serves_the_real_router_over_idfon_h1` serves
`router(state)` through `idfon_h1::serve_router` and drives `/healthz`, `/stats`
and `/ws` (the unmodified `ws_handler`/`handle_socket`: hello line arrives,
`sz,640,480` reaches the hub) from a second endpoint. It is a dev-dependency
experiment — the idfon crates are absolute paths into the idfon worktree until
this branch is pushed or merged.

Two caveats belong to the demo, not this crate:

- A WS session owns one QUIC stream, so today's TCP-style head-of-line remains.
  Channel sharding over separate connections is [#142] slice 4, where the perf
  win lives; measure before/after, do not assume.
- voxl must extract `handle_message` + `READ_ONLY_COMMANDS` out of
  `handle_socket` **before** a second carrier exists, or the iroh path silently
  bypasses read-only mode.

## Manual smoke test (two processes or two machines)

```sh
# machine A — prints the ticket and the iroh address
cargo run -p idfon-h1 --example h1_demo -- serve
# machine B
cargo run -p idfon-h1 --example h1_demo -- get --peer '<ticket>' --path /whoami
cargo run -p idfon-h1 --example h1_demo -- get --peer '<ticket>' --path /sse    # 3 events, 1/s
cargo run -p idfon-h1 --example h1_demo -- ws  --peer '<ticket>' --path /ws     # 101 + echo
```

The ticket is the peer's `EndpointAddr` as JSON — endpoint id plus addresses. No
port, certificate, or token is involved. Verified across two processes on one
host: `GET /whoami` returned the client's endpoint id after a ~1.1 s dial, `/sse`
delivered three events over ~3 s (streamed, not buffered), and `/ws` answered
`101 Switching Protocols` and echoed two text messages.

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
