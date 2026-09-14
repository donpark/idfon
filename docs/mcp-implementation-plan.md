# MCP Integration — Implementation Plan

> **Status:** implemented (M1–M5) on branch `mcp` (2026-09-13). Prototyping
> stage: no legacy or migration constraints. MCP revision **2026-07-28**.
>
> Read the two companion docs first (`docs/mcp-transport.md`,
> `docs/mcp-agent-report.md`). This plan resolved their open decisions into
> defaults; each milestone below is implemented and has an acceptance script.

## How to use this

Milestone 1 proves the wire binding without touching `idfond`. This is not a
throwaway: the **agent side legitimately embeds the node** (no daemon), so M1's
own-key, own-endpoint shape is the correct agent-side architecture, not a
shortcut. What M2+ adds is the **user side** — daemon-owned identity, peers,
and grants. Do not pull later milestones into M1.

Unless stated otherwise, a milestone is done when its acceptance check runs
green and is committed as a script, in the style of `scripts/test-cli.sh`.

## Implementation status

All five milestones are implemented (2026-09-13). Commit and acceptance
script per milestone:

| milestone | commit | acceptance |
|---|---|---|
| docs (this plan + companions) | `cfc0322` | — |
| M1 transport bridge | `284fe8e` | `scripts/mcp-e2e.sh` |
| M2 daemon relay | `0652d2b` | `scripts/mcp-daemon-e2e.sh` |
| M3 contact ticket + discovery cache | `20878e6` | `scripts/mcp-ticket-e2e.sh` |
| M4 idfon as an MCP server | `ac1140e` | `scripts/mcp-server-e2e.sh` |
| M5 open capability names | `72bfe84` | `scripts/test-cli.sh` (+ M1–M4 scripts) |

Verification at completion: `cargo test -p idfon-protocol -p idfon-core
-p idfon-daemon` (8/7/20), `scripts/test-cli.sh` green, all four MCP e2e
scripts green, and the user-side frontends (macOS and iOS Swift, and the
`native/` TypeScript host) build/check clean against protocol version 2.

## Resolved decisions

| decision (from report) | default | note |
|---|---|---|
| D2 bridge vs host-implemented transport | **bridge** | agent side embeds `idfon-core` (no daemon); bridge exposes local stdio and tunnels over iroh |
| deployment shape | daemon on user side, embedded node on agent side | a daemon is warranted only when multiple local processes share one identity |
| D3 stream vs message profile | **stream first** | message profile deferred until offline peers are a real requirement |
| D5 capability names | **open namespaced strings** | deferred to milestone 5; not needed for the binding |
| D6 shared result vocabulary | **yes** | follows D5 |
| D7 computer-use as namespace | yes | later milestone |
| D8 ACP | adapter only, last | not in M1-M5 |

One correction to the companion docs while implementing: **the stream-profile
bridge does not parse MCP at all.** It is a byte pump between a reliable
bidirectional byte stream and an iroh bi-stream. Newline framing is preserved
verbatim. The only place a bridge ever parses JSON-RPC is the optional
`server/discover` cache (milestone 3). If an implementation of M1 has an MCP
method name in it, it is over-built.

## Milestone 1 — prove the binding (agent-side node, no daemon)

### Goal

Two processes on different machines can carry newline-delimited JSON-RPC over
`idfon/mcp/1` such that a stock MCP client/scenario works against a stock MCP
server, with the bridge in the middle doing nothing but moving bytes.

### In scope

- A standalone binary `idfon-mcp` with two modes:
  - `idfon-mcp serve --mcp-command "<cmd> [args...]"` — accepts inbound
    `idfon/mcp/1`, splices each bi-stream to a freshly spawned local MCP
    server's stdio. Prints its endpoint ticket on startup.
  - `idfon-mcp connect --peer <ticket|endpoint-id>` — dials a peer, opens one
    bi-stream, splices it to its own stdio (so an MCP host can `spawn` it as a
    normal stdio server).
- ALPN `idfon/mcp/1`, newline-delimited UTF-8 JSON-RPC both ways.
- Cancellation = close the stream. No `notifications/cancelled` in this
  profile.
- `subscriptions/listen` works by simply leaving the stream open and relaying
  notifications; no special handling.
- A fixture MCP server implementing `server/discover`, `tools/list`, and one
  `tools/call`, used by the acceptance script.
- Identity: `idfon-mcp` takes its key from `--key-file` or `IDFON_MCP_KEY`,
  and generates an ephemeral one only if neither is set (with a warning).
  Stable keys keep grants valid across runs.

### Out of scope (M1)

Daemon changes; the user-side daemon path; peer store; grants; contact
tickets; discovery caching; voice/media; ACP; json-render; screen/camera;
message profile; agent-to-agent; anything named after an MCP method other than
the fixture.

### Architecture

```
MCP host ──stdio──▶ idfon-mcp connect ──iroh idfon/mcp/1──▶ idfon-mcp serve ──stdio──▶ MCP server
```

Each `connect` invocation owns one bi-stream and one local stdio pair. Each
inbound bi-stream on `serve` gets its own spawned MCP server process. Lifecycle
is stream-scoped: stream closes → child is terminated and reaped.

The binary embeds `idfon-core` and owns its own iroh key and endpoint, so the
binding is proven with **zero changes to `idfond`**. This is the correct shape,
not a prototype: an agent is a single sandboxed process and does not need a
daemon (a daemon is only warranted when several local processes share one
identity). `idfon-client` must not be a dependency of `idfon-mcp`.

Because the key is provisioned into the sandbox rather than owned by a daemon,
either provision a **stable** key (mounted secret / env) so grants survive
across runs, or accept **ephemeral** identity with per-session capability
tickets. Make this explicit in the CLI (`--key-file` / env), and do not
silently generate a fresh key on every run.

### Repo touchpoints

- **New crate `crates/idfon-mcp`**, binary `idfon-mcp`, added to `members` in
  the root `Cargo.toml` (currently 7 crates:
  `idfon-protocol, idfon-core, idfon-media, idfond, idfon-cli, idfon-client,
  idfon-daemon`).
- Endpoint creation: reuse `idfon-core`'s `IrohTransport`. It binds headlessly
  with `bind_with_key(Some(key))` and has no daemon dependency. Two small
  additions are needed:
  - accept side: after `bind_with_key`, call `add_side_channel(b"idfon/mcp/1",
    tx)` — this already registers an extra ALPN today (see `idfon-media`).
  - dial side: `IrohTransport::send` hardcodes `MESSAGE_ALPN`, so add an
    ALPN-aware outbound method (e.g. `open_bi_stream(target, alpn)`). This is
    the one idfon-core change M1 needs; do not reach for a raw
    `iroh::Endpoint` in the new crate to avoid it.
  The agent's endpoint is its own identity; it is not the user's messaging
  identity, and that is correct — do not wire it to a daemon.
- Framing helper: a small `copy_bi_stream<S: AsyncRead/write>`-style pump.
  Newline-delimited JSON-RPC means the pump is byte-for-byte; it must not
  parse, re-serialize, or re-frame.
- Reference for the ALPN registration pattern for the **user-side** relay in
  M2: `crates/idfon-media/src/live.rs:285` and `video.rs:442` call
  `transport.add_side_channel(iroh_live::moq::ALPN, tx)`. That is the model to
  copy.

### Acceptance

New script `scripts/mcp-e2e.sh` (same preamble style as `scripts/test-cli.sh`:
build, run, `PASS:`/`FAIL:` lines, non-zero on first failure). It must:

1. Start the fixture MCP server via `idfon-mcp serve`, capture its ticket.
2. Start `idfon-mcp connect` against it and speak MCP over its stdio with a
   small Python driver (the repo already depends on python3 in several e2e
   scripts):
   - `server/discover` → assert `supportedVersions` contains `2026-07-28`,
     `resultType == "complete"`, `capabilities.tools` present.
   - `tools/list` → assert the fixture tool is listed.
   - `tools/call` → assert the echo result.
   - a version-mismatch request → assert JSON-RPC error `-32022`.
   - `subscriptions/listen` → keep the stream open, have the fixture emit one
     notification, assert the notification arrives framed correctly, then
     close and assert the stream closes.
3. Assert the pump preserves framing under a message containing escaped
   characters (no raw newline injected).

A green run of that script is the definition of done for M1.

## Milestone 2 — user side: authorization and the local relay

The agent side never gains a daemon. This milestone is **user-side only**,
where `idfond` already owns the endpoint and identity.

- **Inbound** (an agent calls the user's idfon MCP server): `idfond` registers
  `idfon/mcp/1` via `add_side_channel` on the daemon-owned transport, exactly
  like `idfon-media` (`crates/idfon-media/src/live.rs:285`), and splices to a
  configured local command. It must not learn MCP.
- **Outbound** (the user's MCP host dials an agent): the daemon must expose a
  bi-stream to a local process. Two shapes:
  - a Unix socket per peer (`<data_dir>/mcp/<peer-id>.sock`) that the daemon
    splices to the peer's bi-stream, with a tiny stdio↔UDS shim for hosts that
    only speak stdio; or
  - an `open-alpn-stream` IPC method with stream multiplexing added to the
    daemon protocol.
  Prefer the UDS-per-peer shape — it avoids IPC multiplexing entirely.
- **Authorization**: a grant (namespaced, e.g. `mcp.transport`) gates which
  peers may use the ALPN in each direction. Reuse `access.check` /
  `access.grant`; do not invent a second permission system.
- This is the only place the daemon-relay problem exists. The agent-side bridge
  from M1 remains daemon-free and unchanged.

## Milestone 3 — contact ticket and discovery cache

- Define a **new** ticket/record type. There is no contact ticket today:
  `endpoint_ticket_for` returns `endpoint_addr` as `Vec<u8>`, and
  `CapabilityTicket` is the grant ticket. This is net-new.
- The ticket carries `{ transport, peer, discover? }` where `discover?` is a
  cached `DiscoverResult`.
- CLI: `idfon peer add --mcp-ticket <ticket>` (or equivalent), so adding an
  agent is a contact-add with no config edit and no host restart.
- Invariants: respect `ttlMs`/`cacheScope` (treat as cache, refresh with a
  live `server/discover`); `serverInfo` is **unverified** — display only.
- Acceptance: add a peer from a ticket offline, then have `server/discover`
  succeed on first live connection.

## Milestone 4 — idfon as an MCP server

- User-side only. A separate adapter (process over `idfon-client`; not in
  `idfond`) exposing idfon capabilities as MCP tools: send message, list
  peers, put/get blob, start stream, etc.
- Map each tool to a grant/lease; the consent decision is idfon's, and the
  adapter surfaces it. This is the device-capability consent MCP lacks.
- Acceptance: an MCP client can call `idfon.put_blob` and `idfon.send_message`
  against a throwaway daemon.

## Milestone 5 — open capability names and invocation vocabulary

- Protocol-wide change: `Capability` (currently a closed serde enum in
  `crates/idfon-protocol/src/lib.rs`) → namespaced strings. Opaque args,
  provider-declared schemas.
- One shared result vocabulary: `text | render | blob ticket | stream ticket |
  error`.
- Because it touches the wire, this milestone must update
  `docs/protocol.md` and add/update assertions in `scripts/test-cli.sh`, per
  the versioning discipline. Adding optional params does not bump
  `PROTOCOL_VERSION`; changing the `Capability` type does.

## Later (do not start)

- Voice: modality negotiation, transcript-first, media binding.
- Device capture: capture provider, leases, subject-bound stream tickets.
- Message profile (store-and-forward MCP for offline peers).
- ACP adapter for conversation.
- json-render in the update stream.
- Agent-to-agent, with loop/rate guards.
- Agent key rotation / stable logical agent id.

## Implementer notes and pitfalls

- **Newline framing:** JSON-RPC bodies are single-line JSON; a `\n` terminates
  a message. Never pretty-print on the wire.
- **No SSE keep-alives needed** on QUIC, but consider idle timeouts for a
  `subscriptions/listen` stream that goes quiet.
- **Do not parse `_meta`.** Version rejection (`-32022`) is the MCP server's
  job; the bridge relays it.
- **Do not implement the legacy `initialize` handshake.** Target `2026-07-28`
  only; dual-era support is out of scope.
- **One stream per logical MCP connection.** Do not multiplex streams inside a
  bi-stream; open a new bi-stream instead.
- **Reap children.** A closed stream must terminate its spawned MCP server;
  otherwise `serve` leaks processes.
- **The daemon stays dumb.** M2 may put a relay in `idfond` for the user side;
  the daemon still must not know what a tool, MCP method, or agent is. The
  generic primitive is "ALPN → spawn/splice", not "MCP".
- **The agent bridge never links `idfon-client`.** Adding it would reintroduce
  the daemon the sandbox does not have.
