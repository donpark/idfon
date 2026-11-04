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

### Is this worth it? The TCP baseline

`cargo test -p idfon-h1 -- --ignored --nocapture tcp_ws_baseline` runs the same
WS echo and 12 MiB bulk over **plain TCP loopback**, which is the thing iroh has
to beat or justify. Same host, same frame sizes:

| transport | 1 KiB p95 | 64 KiB p95 | 12 MiB bulk |
| --- | --- | --- | --- |
| plain TCP (baseline) | 0.13 ms | 0.26 ms | ~3.1 GiB/s |
| iroh direct, loopback | 0.26–0.39 ms | 4.0–4.9 ms | ~27 MiB/s |
| iroh over N0 relay | ~48 ms | ~132 ms | ~1.7 MiB/s |

Read this honestly: **iroh costs ~2× the frame latency and ~100× the bulk
throughput of plain TCP on the same machine.** That is QUIC in userspace: packet
pacing, congestion control, per-stream windows, encryption. It is not the h1
adapter's fault — h1 is a thin duplex over the QUIC stream — and it does not go
away with more engineering on this layer.

So "is WS over iroh worthwhile?" depends entirely on what it replaces:

- **Against a LAN TCP port you can already reach:** no. Bind a port and use
  plain WS. iroh buys you nothing and costs you ~2× latency / ~100× bulk.
- **Against "the user's server is behind NAT and you cannot port-forward":**
  yes, and the numbers say it comfortably clears the voxl bar. 27 MiB/s is
  ~220 Mbps, 15–40× what 1080p60 H.264 needs; 64 KiB frames at p95 4–5 ms leave
  ~3× headroom at 60 fps. The value is zero-config NAT traversal, identity and
  encryption — not throughput.
- **Relay-only deployments:** the ~1.7 MiB/s / ~132 ms row is the constraint.
  14 Mbps ≈ 29 KiB/frame at 60 fps: fine for control and audio, not full-motion
  1080p. That is what channel sharding (slice 4) is for.

The earlier loopback-only table is kept below as the adapter's own ceiling —
what iroh+hyper can do with no network in the way — not as an end-to-end number.

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

### Raw numbers, both paths

Throughput (`cargo test -p idfon-h1 -- --ignored --nocapture throughput`), 12 MiB
each way. Two runs of the same bench, differing only in the path iroh selects:

| path | download | upload | 1 KiB WS p95 | 64 KiB WS p95 |
| --- | --- | --- | --- | --- |
| direct, loopback QUIC | ~217–270 Mbps | ~221–290 Mbps | ~0.3 ms | ~4.0–4.9 ms |
| public N0 relay | ~14 Mbps | ~11 Mbps | ~48 ms | ~132 ms |

Both rows print the selected path (`PATH direct (127.0.0.1)` vs
`PATH relay-only (advertised)`), so a number cannot be silently attributed to
the wrong path. Relay rows use `IDFON_RELAY_ONLY=1`, the same knob the apps honor
(`idfon-core` clears IP transports, so only the relay address is published) —
`docs/benchmarks.md` uses it for the same reason. h3 measured 9 Mbps down on the
same relay run; both protocols are relay-bound there.

Frame latency over the WS echo path — p95 is the ceiling for a stop-and-wait
protocol; a pipelined sender is bounded by bandwidth instead:

| message | direct p95 | direct ceiling | relay p95 | relay ceiling |
| --- | --- | --- | --- | --- |
| 1 KiB control | 0.26–0.39 ms | ~2,500–3,800 fps | ~48 ms | ~21 fps |
| 64 KiB frame | 4.0–4.9 ms | ~205–250 fps | ~132 ms | ~8 fps |

What that means for the demo:

- **Direct P2P** has ~4× headroom at 60 fps for a 64 KiB frame, and the
  217–258 Mbps budget is ~450 KiB/frame. Nothing here limits a LAN demo.
- **Relay** does not carry 60 fps stop-and-wait: 8 fps at 64 KiB, 21 fps at
  1 KiB, and ~29 KiB/frame at 60 fps from bandwidth alone. That is the number
  that makes channel sharding and pipelining a *product* requirement rather
  than a nicety, and why slice 4 exists.
- The direct row is loopback, not a LAN. The two-host LAN/netem run in [#142]
  is still the missing real-world "direct P2P" number; until then, treat
  loopback as the best case and relay as the worst case.

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
