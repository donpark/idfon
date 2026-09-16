# idfon Eve Channel — Implementation Plan

> **Status:** M0–M5 agent messaging, M4 HITL/status flows, and M3 files-in,
> files-out, live audio, and live video are implemented. Remaining operational
> work, including the validated iOS text-agent demo, is documented in `docs/ios-architecture.md`.
> Design: MCP bridge pattern from `docs/mcp-implementation-plan.md` (M1–M5,
> implemented). Prototyping stage: no legacy or migration constraints. Eve
> channel contract as of 2026-09-14 (`defineChannel`, routes/events,
> `from(address).send`, `sessionAuth`, `turnPolicy`, `audience`, extensions;
> pinned Eve `0.55.0`).

## How to use this

M0 proves the channel-contract fit without any endpoint work. M1 builds the
endpoint holder; M2 wires the Eve channel to it. Each milestone is independently
useful and leaves no dead surface. A milestone is done when its acceptance
script runs green and is committed, in the style of `scripts/mcp-e2e.sh`.

The core architecture decision is already resolved by the MCP work: **the agent
side embeds the node (`idfon-core`), no daemon.** The holder is a single
sandboxed process that owns the endpoint, exactly like `idfon-mcp`. Do not link
`idfon-client` from the holder.

## Implementation status

| milestone | commit | acceptance |
|---|---|---|
| docs (this plan + `idfon-eve-channel.md`) | — | — |
| M0 contract spike | `47049b0` | `scripts/eve-channel-spike.sh` |
| M1 endpoint holder | `47049b0` | `scripts/eve-channel-holder-e2e.sh` |
| M2 Eve channel provider | `8c1e757` | `scripts/eve-channel-e2e.sh` |
| M3 media — files in | `efdcf73` | `scripts/eve-channel-media-e2e.sh` |
| M3 media — files out | `8976324` | `scripts/eve-channel-media-out-e2e.sh` |
| M3 media — live streams | `8976324` | `scripts/eve-channel-live-e2e.sh` |
| M4 HITL — approvals/input | `890071a` | `scripts/eve-channel-hitl-e2e.sh` |
| M4 HITL — authorization/status flows | `9a1bf5b` | `scripts/eve-channel-hitl-e2e.sh` + holder IPC tests |
| M5 agent-to-agent + isolation | `6e6592d` | `scripts/eve-channel-a2a-e2e.sh` |

## Resolved decisions

| decision | default | note |
|---|---|---|
| agent-side daemon | **none** | holder embeds `idfon-core`, owns its key/endpoint, like `idfon-mcp` |
| packaging (M1–M5) | **managed runner** | `managed.mjs` owns the holder + bridge lifecycle today |
| packaging (future) | **managed child** | extension spawns the holder when Eve exposes a lifecycle hook |
| IPC | **newline-delimited JSON over a Unix socket** | same framing style as `docs/protocol.md`; no HTTP needed |
| ALPN | **`idfon/message/1`** | the existing message plane; no new ALPN |
| threading | **`MessageEnvelope.conversation`** | already signed and on the wire; no protocol change |
| address | **`peer_id` (+ `conversation`)** | peer+thread → `sessionId`, persisted by the channel |
| auth | **per-message `verify_message` + capability ticket** | holder verifies before the channel sees the turn |
| audience | **authenticated idfon sessions are private** | Eve `0.55` `audience({ auth })` classifies the session; unauthenticated context fails closed to unknown |
| default `turnPolicy` | **`queue`** (configurable) | remote peers expect turn-ordered replies; Eve channel default is `steer` |
| A2A outbound | **`idfon__send` tool** | uses the holder's authenticated endpoint and a caller-supplied capability ticket; it is separate from channel ingress |
| A2A authorization | **`agent.receive`** | A2A envelopes require this grant in addition to `message.receive`; ordinary peer turns remain human/agent-neutral |
| A2A loop bound | **depth 1** | replies increment the signed text envelope depth; the channel ignores depth > 1 |
| rate limit | **120 accepted messages / peer / minute** | bounded in-memory window; oversized resource sets and live publishers are rejected |
| live lifecycle | **one-hour TTL** | holder cleanup stops abandoned audio/video publishers; override with `--live-ttl-secs` |
| media wire shape | **out-of-band ticket envelopes** | keep `MessageContent` Text-only; use `IDFON-DATA/1` for blobs and `IDFON-LIVE/1` for live audio, with no protocol bump |
| streaming replies | **coalesce per turn** | token deltas deferred; a stream ticket can carry live media separately |
| node in-process addon | **later** | no Node iroh binding exists; do not build speculatively |

## Milestone 0 — prove the channel-contract fit

### Goal

Show that an inbound idfon-shaped turn can drive an Eve session and that a reply
can be delivered back, using only documented channel surfaces, with no endpoint
holder. This validates the M2 design cheaply.

### In scope

- A throwaway `agent/channels/idfon.ts` in a scratch Eve app that:
  - accepts a `POST /idfon/turn` loopback route carrying `{ peerId, conversation,
    text }` (standing in for the holder),
  - calls `from(addr).send(text, { auth })` where `addr = peerId` or
    `peerId:conversation`,
  - registers an `events["message.completed"]` handler that appends the reply to
    a local file (standing in for `message.send`),
  - returns `sessionAuth` from `auth`.
- A throwaway driver (bash + curl) that posts two turns to one address and
  asserts both replies land in the file and share one session.

### Out of scope (M0)

iroh, the endpoint holder, real peer verification, media, HITL, packaging.

### Acceptance — `scripts/eve-channel-spike.sh`

1. `eve dev` the scratch app (or `eve start` on a temp port).
2. POST turn 1 → assert a reply appears; capture the session id.
3. POST turn 2 to the same address → assert the same session id and a second
   reply.
4. POST with a different `peerId` → assert a different session id.
5. Assert `auth` surfaced the peer as `session.auth.initiator` (via a hook or a
   debug route).

## Milestone 1 — the endpoint holder

### Goal

A standalone binary `idfon-eve-channel` that owns an idfon endpoint, accepts
authenticated inbound messages, emits normalized turns on a local socket, and
sends replies (and later, media/HITL events) back over `message.send`.

### In scope

- New crate `crates/idfon-eve-channel`, binary `idfon-eve-channel`, added to
  root `Cargo.toml` members.
- Modes:
  - `idfon-eve-channel serve --socket <path> [--key-file <path>] [--allow <peer-id>]...`
    — bind the endpoint, serve `idfon/message/1`, write inbound turns to the
    socket, read outbound frames from the same socket, print the endpoint ticket
    on startup.
- Identity: key from `--key-file` / `IDFON_EVE_CHANNEL_KEY`; ephemeral only with
  an explicit `--ephemeral` and a warning. (Same discipline as `idfon-mcp`: a
  stable key keeps grants valid across runs.)
- Inbound: reuse `IrohTransport::serve(handler)` and
  `idfon_core::verify_message`. `MessageContent::Text` → a turn frame. Ignore or
  reject non-Text until M3.
- Authorization: require a valid `capability_ticket` containing
  `message.receive` (`verify_capability_ticket`), and refuse peers not in
  `--allow` (or, later, a persisted peer store). Materialize the reciprocal
  `message.send` grant the same way the daemon does.
- Idempotency: dedupe on `(peer_id, idempotency_key)` in memory for the process
  lifetime, mirroring the daemon's rule; a duplicate with different content is
  rejected. Do not derive keys from client session state.
- Outbound: a `message.send` frame from the socket → build a `MessageEnvelope`
  with `sign_message` and `IrohTransport::send`. Reply target = the peer's
  `EndpointAddr` captured from the inbound connection.
- IPC framing: 4-byte little-endian length prefix + JSON, one request → one
  response (matches `docs/protocol.md`). Frames: `{ "type": "turn.in", ... }`,
  `{ "type": "reply.out", ... }`, `{ "type": "error", ... }`.
- Side-channel ALPNs (`add_side_channel` + `open_bi_stream`) are registered but
  unused in M1; they are the hook for M3 live media.

### Out of scope (M1)

Eve; the channel module; media; HITL; persisted peers/grants; packaging;
managed child.

### Architecture

```text
idfon peer ──idfon/message/1──▶ idfon-eve-channel ──uds json──▶ <socket consumer>
                    ▲                                      │
                    └────────── message.send ◀──── reply.out┘
```

### Repo touchpoints

- `crates/idfon-eve-channel/src/main.rs` — CLI, endpoint, IPC loop.
- Reuse, don't reinvent:
  - `idfon_core::IrohTransport::{bind_with_key, serve, send, open_bi_stream}`.
  - `idfon_core::{sign_message, verify_message, verify_capability_ticket}`.
  - `idfon_protocol::{MessageEnvelope, MessageContent, MessageAck}`.
- The `idfon-mcp` crate is the structural template (CLI shape, key loading,
  `add_side_channel`, no `idfon-client` dependency).

### Acceptance — `scripts/eve-channel-holder-e2e.sh`

1. Start a throwaway `idfond` peer (`IDFON_PROFILE`) with a grant to send to the
   holder.
2. Start `idfon-eve-channel serve --socket <path> --key-file <path>`; read its
   ticket; add it as a peer to the daemon; issue a capability ticket.
3. `idfon send <holder> "hello"` → assert a `turn.in` frame with the right
   `peer_id` and text on the socket.
4. Write a `reply.out` frame to the socket → assert `idfon events` on the peer
   shows the reply.
5. Replay the same `idempotency_key` with the same content → assert deduped, no
   second `turn.in`.
6. Tamper the signature → assert rejection and no `turn.in`.
7. Missing/expired capability ticket → assert `capability_denied`.

## Milestone 2 — the Eve channel provider

### Goal

An installable Eve channel provider: an idfon peer messages the agent and gets a
reply, end to end, with the peer as the session principal.

### In scope

- An authorable channel `agent/channels/idfon.ts` using `defineChannel`:
  - `auth` (`AuthFn`): map the holder-attested `peer_id`/`endpoint_id` to
    `sessionAuth` (`principalId`, `principalType: "idfon-peer"`,
    `authenticator`, `attributes`).
  - inbound: each `turn.in` frame → `from(address).send(text, { auth })` where
    `address = peer_id` (or `peer_id + ":" + conversation`).
  - `events`:
    - `message.completed` → `reply.out` (reply delivery),
    - `turn.started` / `actions.requested` → optional status frames,
    - `input.requested` / `authorization.required` → M4.
  - `receive(input, { from })`: cross-channel sends (another channel handing a
    turn to a peer).
  - `turnPolicy`: `queue` by default, overridable.
  - `audience`: derive from peer grants/visibility; default `unknown`.
  - `metadata(state)`: expose `peer_id`/`conversation` for instrumentation.
- A socket client module that:
  - connects to the holder socket, reads frames, dispatches to the channel,
  - writes `reply.out`/status frames from event handlers.
- An idfon-provider extension package (`integrations/eve-idfon-channel/` or a
  new `eve/` workspace member) so it is installable, with config for the socket
  path and (later) the key.
- Packaging: **external sidecar** for M2 (operator runs the holder); the channel
  takes `socketPath` as config.

### Out of scope (M2)

Managed-child packaging; media; HITL; agent-to-agent; multi-thread UI; presence.

### Architecture

```text
idfon peer ──▶ idfon-eve-channel ──uds──▶ idfon channel (defineChannel) ──▶ Eve session
                      ▲                          │
                      └──── reply.out ◀── events (message.completed) ──┘
```

### Repo touchpoints

- `integrations/eve-idfon-channel/` (or `eve/`) added to `pnpm-workspace.yaml`.
- Channel file lives in the consuming Eve app under `agent/channels/idfon.ts`;
  the extension contributes it. Route paths stay unprefixed; the channel id is
  namespaced by the extension mount.
- No `idfond` changes. The user side is untouched.

### Acceptance — `scripts/eve-channel-e2e.sh`

1. Start the holder (M1) and a scratch Eve app with the idfon channel mounted,
   host/port set to loopback.
2. Add the holder as a peer in a throwaway daemon; `idfon send` a turn.
3. Assert the agent replies on the same address (`idfon events`), and that a
   follow-up resumes the same session (hook/route prints the session id).
4. Assert a second peer gets a distinct session.
5. Assert `turnPolicy: "queue"`: two quick sends produce two ordered turns.
6. Assert an unauthenticated/unauthorized peer is rejected by `auth` (no turn).

## Milestone 3 — media (blob tickets and stream tickets)

### Goal

Carry durable files and live media as turn input/output, beyond Slack's text +
image ceiling.

### In scope

- **Files in — implemented here**: an `IDFON-DATA/1` message referencing a blob
  ticket becomes an Eve `UserContent` file part. The holder fetches it with
  `iroh-blobs` and the channel's `fetchFile` resolves the `idfon-blob:` URL.
- **Files out — implemented**: the `idfon__put` tool stores base64 output in
  the holder's `iroh-blobs` store and returns an `IDFON-DATA/1` ticket envelope.
- **Live media — implemented**: the `idfon__publish-live` and `idfon__stop-live`
  tools drive the pinned `idfon-media`/`iroh-live` file publisher; the returned
  `IDFON-LIVE/1` ticket is subscribed to through the existing MoQ plane, outside
  Eve's session model.
- Wire shape: extend `MessageContent` with a media/blob variant **or** continue
  the daemon's out-of-band `IDFON-DATA/1` text envelope. Choose the smaller
  change; if `MessageContent` changes, bump `PROTOCOL_VERSION` and update
  `docs/protocol.md` and `scripts/test-cli.sh` per versioning discipline.
- The holder keeps the `idfon-media` publisher alive in a managed sidecar
  endpoint; live bytes ride its pinned `iroh-live` MoQ plane rather than the
  Eve session transport.

### Out of scope (M3)

Capture (microphone/camera), rendition adaptation policy, recording storage UX.

### Acceptance — M3 media scripts

1. **Implemented:** put a file into the peer's blob store; send an
   `IDFON-DATA/1` ticket envelope; assert the Eve turn includes the file part and
   `fetchFile` completes the holder fetch round trip.
2. **Implemented:** `idfon__put` emits a blob ticket; `idfon get` fetches it
   from the holder and compares bytes (`scripts/eve-channel-media-out-e2e.sh`).
3. **Implemented:** `idfon__publish-live` emits live audio or video tickets;
   the peer subscribes and validates a decoded WAV or H.264 stream
   (`scripts/eve-channel-live-e2e.sh`, with `EVE_LIVE_VIDEO=1` for video).

## Milestone 4 — human-in-the-loop

### Goal

Approvals and elicitations park the turn and round-trip over idfon.

### In scope

- **Implemented:** `events["input.requested"]` emits an authenticated
  `IDFON-HITL/1` request carrying request IDs, prompts, and options; a peer's
  `IDFON-HITL-RESPONSE/1` message is validated and delivered through
  `from(address).respond(inputResponses, { auth })` (never `send`).
- **Implemented:** `authorization.required` / `authorization.completed`,
  `turn.cancelled`, and `turn.failed` are emitted as authenticated
  `IDFON-STATUS/1` messages. The validated ticket's grants are preserved in
  Eve `session.auth.current.attributes.capabilities`, so approval policies can
  require an idfon grant such as `consent.approve`.
- Provider OAuth completion still occurs through Eve's callback URL; an idfon
  peer receives the challenge/status but cannot impersonate the callback.


### Acceptance — `scripts/eve-channel-hitl-e2e.sh`

1. **Implemented:** trigger a tool with `approval: always()`.
2. **Implemented:** assert the peer receives a request message with options.
3. **Implemented:** reply `approve` → assert the turn resumes and executes;
   reply `cancel` → assert the tool does not run.
4. **Implemented:** responses use `respond`, not `send`, so they do not steer
   the parked turn.

## Milestone 5 — agent-to-agent and isolation

### Goal

A second agent (an idfon peer) can drive the agent, safely.

### In scope

- Per-peer session isolation (already the address model) plus a bounded A2A depth
  guard to stop agent↔agent loops.
- An `idfon__send` Eve tool backed by the holder's authenticated `peer.send`
  frame. The tool requires the destination endpoint and capability ticket, and
  supports the existing optional conversation address.
- `IDFON-A2A/1` text envelopes carried inside signed messages. Replies
  increment depth, preserving ordinary idfon message authentication and
  idempotency underneath.
- Optional reply-ticket provisioning for holder-to-holder replies. A holder
  only attaches its configured reply ticket when its issuer matches the target
  peer; daemon peers continue to receive legacy ticketless replies.
- Grants: distinct policy for agent peers vs human peers if needed.

### Out of scope (M5)

Act-as-user delegation; multi-agent orchestration; a global agent directory.

### Acceptance — `scripts/eve-channel-a2a-e2e.sh`

1. Start two Eve agents with the idfon channel and a third fixture peer for
   the initial turn.
2. Agent A invokes `idfon__send` to agent B with B's capability ticket; B
   replies and the fixture peer receives A's result.
3. Deliver a depth-2 turn and assert the channel returns `a2a_loop_guard`;
   assert B's depth-1 reply is received by A without another outbound loop.

## Remaining hardening

The remaining work is now operational rather than a missing milestone:

- Exercise the rate and resource limits under production load and tune their
  defaults.
- Expand multi-peer and multi-conversation isolation tests beyond the current
  bounded A2A fixture.
- Decide whether the managed runner should become a future Eve lifecycle hook;
  Eve 0.55.0 custom channels do not expose a startup hook, so
  `integrations/eve-idfon-channel/managed.mjs` is the explicit deployment
  entrypoint today.
- Add capture-device and voice negotiation support if the product needs live
  microphone/camera input; file-backed audio/video output is covered.
- Keep the validated iOS text-agent path covered by device E2E when changing
  ticket handling or message persistence.

## Later (do not start)

- **Native Eve lifecycle hook**: the extension itself cannot spawn the holder
  on Eve 0.55.0 because custom channels have no startup hook. The explicit
  `managed.mjs` runner now couples holder + bridge lifecycle; revisit an
  in-extension child when Eve exposes the required hook.
- **Node N-API addon**: expose `idfon-core` to Node; drop the holder process.
  Gate on the sidecar proving the semantics.
- Multi-thread UI (`conversation` → threads), presence/typing, voice
  negotiation, agent key rotation.

## Implementer notes and pitfalls

- **Idempotency keys must outlive the client.** Keys are unique over the
  holder's process lifetime (and the daemon's persisted operations), never
  derived from client session state. A duplicate with different content is a
  conflict, not a resend.
- **Endpoint lifecycle across `eve dev`.** Hot-reload generations reload the
  channel module and can spawn a second holder. Bind to a stable socket path and
  detect an existing holder, or terminate on unload. Production `eve start` is a
  single long-lived process and is unaffected.
- **Trust boundary.** The channel must receive peer identity only from the
  holder's attestation (the IPC channel in M1/M2), never from a client-supplied
  header. In split packaging, attest with a signed frame or a per-install
  secret.
- **Accept-path handshake aborts are background noise** (per the `iroh-protocols`
  skill): log and continue; never let one failed inbound handshake kill the
  accept loop.
- **One message = one connection today.** `IrohTransport::send` connects,
  opens one bi-stream, writes one frame, waits for ack. Fine for turns; revisit
  if throughput matters.
- **Do not parse Eve semantics in the holder.** It normalizes idfon →
  `{peer_id, conversation, text, ticket?}` and back. `defineChannel` owns
  address→session, auth, delivery.
- **Do not add media to M1.** Text-only proves the wire; media is M3.
- **No `idfon-client` in the holder.** Adding it reintroduces the daemon the
  agent does not have.
- **Disable Eve's default HTTP channel** in a real deployment (or loopback-bind
  it) so the no-public-endpoint property holds.
- **Protocol changes need discipline.** Adding optional envelope fields does not
  bump `PROTOCOL_VERSION`; changing `MessageContent` does, and must update
  `docs/protocol.md` + `scripts/test-cli.sh`.
- **Verify Eve API against the current docs** (`eve.dev/docs/channels/custom`,
  `.../extensions`) before implementing; the channel contract moves.