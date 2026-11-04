# idfon-channel: message channels over iroh, no HTTP

The WebSocket *interface* — ordered, reliable, text/binary messages, close —
mapped straight onto iroh bi-streams. One channel owns one QUIC stream, so
there is no HTTP/1.1 request line, no `101` upgrade, and no RFC 6455 header:
a message is one frame, `[kind: u8][len: u32 LE][payload]`.

This is the "interface-level switcheroo" in its honest form: it removes the
HTTP + WS layers but keeps one ordered reliable stream per channel, because
ordering is what the transport already gives and what callers rely on. It does
**not** shard a single logical channel across streams or use QUIC datagrams.

Status: **current** as a library; nothing in the tree consumes it yet (see
"When to use it"). `idfon-h1` remains the compatibility carrier.

## Shape

```text
peer ── iroh connection (ALPN idfon/channel/1) ── one bi-stream
                                                     │
                                    [kind][len][payload] per message
```

- [`serve_channels(&Arc<IrohTransport>, handler)`]: registers
  `idfon/channel/1` as a side channel; the handler runs once per channel with
  `(EndpointId, channel name, Channel)`.
- The **channel name** is the first frame the client sends (`"control"`,
  `"video"`, …). It replaces the HTTP path, and it is what makes sharding a
  naming decision. Names are capped at 256 bytes ([`MAX_CHANNEL_NAME`]): a
  name is a routing key, and an untrusted peer must not be able to hand the
  server a multi-megabyte label.
- [`ChannelClient::connect(&EndpointAddr, name)`] dials one channel. One
  channel = one iroh connection, so its flow control, ordering and loss
  recovery are independent of every other channel.
- [`Channel`] is the socket: `send(Message::{Text,Binary})`, `recv() ->
  Option<Received>`, `close()`. Dropping it closes the channel.
- Handler bodies are the caller's; there is no router and no request type,
  because there is no HTTP.

Run it next to the transport's message loop (`IrohTransport::serve`): that loop
is what dispatches inbound connections by ALPN. It coexists with
`idfon/message/1`, `idfon/http1/1` and `idfon/http3/1` on one endpoint.

## Sharding

One name per logical stream, one connection each. A consumer that stops
draining `video` fills its flow-control window and blocks only itself;
`control` keeps answering on its own connection. That is asserted by
`cargo test -p idfon-channel a_stalled_channel` (16 MiB of video with no
reader, then a control round trip, then teardown of the stalled channel).

On a single WS connection all messages share one ordered stream, which is
exactly the head-of-line behavior sharding removes. Note what sharding does
**not** buy: every channel on the same path still shares the network's
bottleneck and its loss events. The isolation is at the flow-control and
consumer level.

## Measured

Three shapes, because the ranking moves with process topology — which is itself
the answer: no arm is reliably faster than another, because the layer is free
and the path is everything.

**1. One process, one 4-worker runtime** (both endpoints, both QUIC stacks and
the echo sharing cores). `cargo test --release -p idfon-channel -- --ignored
--nocapture overhead`:

| arm | 1 KiB p50 | 1 KiB p95 | 64 KiB p50 | 64 KiB p95 |
| --- | --- | --- | --- | --- |
| WS over h1 (axum `WebSocket` + hyper) | 109–112 µs | 154–160 | 879–921 | 1050–1122 |
| RFC 6455 on a bare iroh stream (no HTTP) | 70–71 | 90–100 | 857–903 | 1037–1046 |
| channel (5-byte header) | 51–72 | 71–102 | 840–887 | 1012–1066 |

Here the channel wins by ~15–40 µs at 1 KiB: with cores oversubscribed,
axum's per-socket writer task (plus its mpsc queue) is the visible cost, not
RFC 6455. The 4 B vs 5 B headers never show up.

**2. Two processes, direct path** (`chan_demo serve` on one side, `bench` on
the other; round 2, after warm-up):

| arm | 1 KiB p50 | 64 KiB p50 |
| --- | --- | --- |
| channel | 100 µs | 1.62 ms |
| WS over h1 | 83 µs | 1.59 ms |

The ranking **flips**, by more than the gap it is trying to measure. With a
spare core the adapter's task costs nothing, and the channel pays for its own
frame parsing. Conclusion: at this scale the two are indistinguishable.

**3. Real network path (N0 relay, `IDFON_RELAY_ONLY=1`), same bench.** The only
row with a network in it — ~44 ms RTT observed:

| arm | 1 KiB p50 | 1 KiB p95 | 64 KiB p50 | 64 KiB p95 |
| --- | --- | --- | --- | --- |
| WS over h1 | 44.155 ms | 47.604 | 103.38 | 112.72 |
| RFC 6455 on a bare iroh stream | 44.242 | 48.031 | 104.53 | 112.64 |
| channel | 43.982 | 47.798 | 104.06 | 112.14 |

All three arms are the same to within noise (0.2–1 ms on 44 ms = 0.5–2%, and
the ordering shuffles). A ~40 µs layer disappears into a real RTT, exactly as
arithmetic says it must.

**4. Two hosts, real wire: Mac ↔ iPhone 16 over Wi-Fi.** The phone ran the
same echo loop in-process (an app launch-argument hook); the Mac benches it
with the command in [Tests and benches](#tests-and-benches):

| arm | 1 KiB p50 / p95 | 64 KiB p50 / p95 | 1 MiB p50 / p95 |
| --- | --- | --- | --- |
| channel | 6.8 / 9.1 ms | 24.1 / 29.9 | 80 / 199 |
| WS over h1 | 7.0 / 9.8 ms | 22.1 / 29.5 | 84 / 200 |

Again the two arms are the same to within noise — the fourth shape, same
answer. What the row does say: **~7 ms RTT on the same LAN** (the phone's
Wi-Fi power save, not the transport), ~25 ms for a 64 KiB round trip, and
~1 MiB per 80 ms each way ≈ 100 Mbps one-way sustained. The voxl bar
(30 Mbps) clears with margin; the layer choice is irrelevant to it.

### Hazards

- **The first connection to a peer often sticks to the relay.** iroh starts on
  the relay while hole-punching settles, and an established connection does not
  migrate to the direct path. A benchmark that dials once measures the relay
  (~44–52 ms per message) and the *next* connection measures the punched path
  — a path-change artifact, not a transport difference. `chan_demo` waits for
  a direct path on a throwaway connection before measuring, and runs two
  rounds; read round 2.
- To pin a specific path (e.g. LAN, not cellular), keep only the wanted entry
  in the ticket's `addrs` before passing it to `bench`; iroh dials what the
  ticket lists.
- Still missing: two *networks* (direct P2P over the internet, hole-punched,
  no relay). Two hosts on Wi-Fi is measured above.

## Limits

`shortcut:` no fragmentation, no ping/pong, no extension negotiation — the
three RFC 6455 features this API does not need. Consequences:

- A message is capped at 16 MiB (payload length is `u32`); a channel name at
  256 bytes.
- Text is decoded lossily (one bad peer must not kill a channel).
- No browser clients: page JS cannot open a UDP/QUIC connection, so browsers
  still need the edge (WS or WebTransport terminated there). This path is for
  native, Node/Deno, or daemon-internal clients.
- No multiplexed request/response: a channel is a message pipe, not HTTP. Use
  `idfon-h1` (streaming, `axum::Router`) or `idfon-h3` (multiplexed
  request/response) when you need the HTTP shape.

## When to use it

- **`idfon-h1`** — anything that already speaks HTTP or WebSockets: an
  existing `axum::Router`, a third-party developer's server, a language whose
  WS library accepts a duplex stream, browsers via the edge.
- **`idfon-channel`** — in-house clients where per-channel isolation matters
  and both ends are ours: voxl's `/ws` split into `control` / `audio` /
  `video`, or a `libiroh_c_ffi` duplex/message primitive for the native apps.

No consumer is wired yet. If neither of those lands, delete this crate and
fold the measurement above into `idfon-h1.md`; a live ALPN with no owner is
worse than a spike in a branch.

## Tests and benches

```sh
cargo test -p idfon-channel                  # round trip (text, 2 MiB binary), close, sharding
cargo test --release -p idfon-channel -- --ignored --nocapture overhead

# two hosts (or two networks): one process serves both arms on one identity
cargo run --release -p idfon-channel --example chan_demo -- serve
cargo run --release -p idfon-channel --example chan_demo -- bench --peer '<TICKET JSON>'
```

The bench compares three arms on the same transports and the same path:
WS over h1, RFC 6455 straight onto an iroh bi-stream, and the channel.

## Rebuild scope

Library-only: nothing to rebuild. Once a binary calls `serve_channels`:
`crates/idfond`/CLI (`pnpm cli build`), the edge image (`deploy/idfon-edge`), or
the eve agents depending on the consumer. Apps only if it is exposed through
the daemon/FFI. See [`build.md`](build.md).
