# idfon as a celld Ingress Adapter

> **Status:** design; no code. Companion to `docs/idfon-eve-channel.md` (idfon as
> an Eve ingress channel) and `docs/idfon-eve-channel-implementation-plan.md`
> (the endpoint holder). This document covers extending or forking
> [denoland/celld](https://github.com/denoland/celld) so a cell can be reached
> over **idfon channels** in addition to, or in place of, HTTP.
> Written 2026-09-14. celld facts verified against `denoland/celld@main`.

## The premise, corrected: idfon is not raw UDP

The natural first sketch is "add a `tokio::net::UdpSocket` listener, read the
cell ID out of the datagram, call `dispatch(cell_id, payload)`, and add a
`udpMessage(bytes, rinfo)` worker event". That is the wrong layer.

idfon rides an **iroh endpoint**: QUIC over UDP with its own handshake, ALPN
negotiation, streams and datagrams, encryption, hole-punching, relay fallback,
and per-message Ed25519 signatures. Consequences:

- A raw `UdpSocket` would have to reimplement QUIC, or bypass it — never.
- It cannot share the port with iroh, which owns its UDP socket and demuxes QUIC
  itself.
- The routing key is not bytes in a payload. It is the **addressed identity**
  (the idfon message's recipient/conversation), and the sender's identity is
  **verified from the signature**, not read out of a header a peer supplies.
- `rinfo` semantics do not exist: a peer is an endpoint id, not an IP:port, and
  the reply is a `message.send` back to that endpoint (direct or via relay).

So the fork point is **"add an iroh ingress adapter"**, not "add UDP". iroh
already did the UDP.

## Why celld is a good host for this

celld's own architecture note is the whole argument:

> `crates/logic` owns all behavioral state and decisions; `crates/celld` is only
> an effect executor and adapter host. (`Cargo.toml`)

and, in `crates/celld/lib.rs`:

> The executable owns one serial actor which is the only caller of
> `celld_logic::on_event`. **Adapter futures never borrow core state; they send
> versioned completion events back through its mailbox.**

That mailbox is the seam. An idfon ingress is **one more event source** feeding
`on_event`, alongside the HTTP listener. Everything hard is then reused
unchanged:

| reused mechanism | where |
|---|---|
| ownership lease (conditional bucket write) | `celld/ownership_store.rs`, `logic/cell.rs` |
| wake / hydration of a hibernated cell | `celld/wake.rs`, `logic/wake.rs` |
| LTX write capture + replication | `celld/ltx_repl.rs`, `celld/replication.rs`, `logic/durability.rs` |
| isolate lifecycle (one V8 isolate per cell) | `celld/js.rs`, `logic/isolate.rs` |
| routing to the owning node | `logic/routing.rs`, `celld/peer_auth.rs` |
| per-cell SQLite storage | `celld/storage.rs`, `logic/sqlite.rs` |
| the Workers handler surface (`fetch`, `alarm`, hibernating WebSockets) | `celld/js.rs` |

This mirrors the idfon-side design: an agent is a peer with a durable session,
and the ingress is an adapter — exactly the role `defineChannel` plays in
`docs/idfon-eve-channel.md`.

## Architecture

```text
idfon peer ── idfon/message/1 (iroh/QUIC) ──▶ [ celld node ]
                                                  │
                                        crates/celld/iroh.rs  (adapter)
                                          bind endpoint, verify envelope
                                                  │
                                     event into actor mailbox (on_event)
                                                  │
                                        crates/logic (routing, wake, lease)
                                                  │
                                        V8 isolate (one per cell) ── fetch(request)
                                                  │
                                          response body / op_idfon_send
                                                  │
   ◀──────────── message.send (iroh) ─────────────
```

The adapter is untrusted-effect-side only: it binds the endpoint, decodes and
verifies an envelope, and hands a normalized event to the actor. `logic` keeps
owning all decisions, so the fork surface stays small.

## Component mapping (your four items, corrected)

| your sketch | corrected |
|---|---|
| **(1) Ingress:** bind `tokio::net::UdpSocket`, parse HTTP requests / datagrams | **`crates/celld/iroh.rs`**: bind an **iroh endpoint** via `idfon-core`/`iroh`, register ALPN `idfon/message/1` (and later `idfon/mcp/1`), accept, decode + `verify_message` + capability ticket |
| target cell ID "from the payload or header metadata" | the **addressed identity/conversation** in the verified envelope — the same job the HTTP listener does when it decides which cell activates |
| **(2) Dispatch:** `dispatch_udp_event(cell_id, payload)` faking a request | **emit an event into the actor mailbox** (`on_event`) that reuses `logic/wake.rs` + `logic/routing.rs` + the ownership lease; no faked HTTP context |
| **(3) JS trigger:** `udpMessage(bytes, rinfo)` custom event | the cell receives the **standard Workers `fetch(request)`** event (v1) — the agent is unchanged across HTTP and idfon |
| **(4) Outbound:** `op_udp_send` | `message.send` — reply path from the response body (v1), or an op á la `celld/js/tcp.rs` (streaming/live media) |

## The adapter-vs-op decision

**Ingress is an adapter; ops are outbound.** In celld, ops (`js/tcp.rs`,
`js/storage_ops.rs`, `js/r2_ops.rs`, `js/websocket.rs`) are the JS→host
direction — "every op is an `asyncrt` promise," sync Rust wrapped async by the
JS harness. Ingress arrives through an adapter that produces an event. There is
therefore no such thing as "ingress via custom op bindings": the two options in
the original question are not symmetric.

The real choice is the **JS-facing shape of the turn**, and v1 takes the
standard one:

### v1 — map to the existing request event (recommended)

The adapter constructs a normal request event (custom scheme/host; attested
headers for `peer_id` and `conversation`; body = message text/parts) and feeds
the same path HTTP uses. Why:

- It is celld's stated contract: the adapter is an effect executor, `logic`
  decides. No new runtime surface, no `logic` change.
- Wake/hydration, leases, LTX replication, SQLite, hibernation, and
  "the listener that receives a request decides where a new cell activates"
  (`docs/README.md`) are inherited unchanged.
- The handler stays `fetch(request)`, so **the same agent runs on HTTP, on
  Cloudflare, and on idfon** — the "in addition to or in place of HTTP"
  requirement, satisfied by construction.
- The reply is the response body; the adapter turns it into `message.send`.
  No op needed for the common case.
- Identity is **trust-by-construction**: the adapter built the request, so the
  peer headers are attested, never client-supplied. (In celld's split-process
  reality, that means the adapter and the actor, not a network peer.)

### Later — narrow custom ops, for what HTTP cannot express

- **Outbound/streaming:** `op_idfon_send` / stream ops modeled on
  `celld/js/tcp.rs` — a process-global registry plus the request-context
  `free(id)` discipline so an abandoned socket cannot outlive its event.
- **Live media:** bridge a returned `ReadableStream` (or an iroh-live/MoQ track
  reference) to idfon's media plane. As in the Eve design, live bytes ride
  idfon, not the session model.

Do **not** start here: it forks the op surface, reimplements dispatch/wake, and
makes the agent non-portable — for a case a response body already covers.

## Identity granularity (the decision your sketch leaves open)

A celld node runs many cells; an idfon identity is an **endpoint key**. Two
shapes:

| shape | how | cost |
|---|---|---|
| **one endpoint per node** | the node holds one idfon identity; agents are addressed by id/conversation, like HTTP hosts | grants/authorization are node-level; an agent is a tenant, not its own peer |
| **one identity per agent** | one iroh endpoint (hence UDP socket) per cell | agent is a true peer with its own key and per-agent grants — what `docs/idfon-eve-channel.md` assumes (agent has a separate identity) |

Candidate default: **node-level endpoint for v1**, keyed by a per-deployment
idfon identity, with the addressed agent id carried in the envelope; revisit
per-agent keys when per-agent authorization or a distinct peer identity is
required. Note the resource implication of per-agent endpoints on a
high-cell-count node.

## Gating question: does the agent runtime run in a cell?

celld executes **Wrangler bundles** in V8 (Workers + Durable Objects, with
`nodejs_compat`, Workflows, alarms, hibernating WebSockets). "Run an Eve agent
on celld" is therefore only real if the agent runtime fits that model:

- A Worker/DO with a `fetch` handler and durable state — yes, directly.
- Celld's **alarms** and **Workflows** map onto a durable session/run model
  (Eve's sessions and runs are durable, resumable, and stream events).
- A Node/Nitro server (Eve's default deployment shape) is a different story;
  confirm Workers compatibility or host the runtime at the edge and keep only
  the idfon ingress adapter in celld.

Resolve this before committing to the fork — it decides whether the idfon
adapter sits in front of a DO or in front of a proxied runtime.

## Fork vs upstream

Your tradeoff holds. Add one point: the **idfon protocol must not be baked into
`crates/celld`**. `verify_message`, ALPNs, grants, and the message plane belong
in an idfon crate; the upstreamable contribution is a **generic pluggable
ingress adapter** (an `--ingress in-process|iroh`-style listener next to
`--listen`/`--internal-listen`), so upstream review is about the seam, not about
idfon. That is the smallest reviewable PR and still yields a single binary with
no gateway hop.

## Milestones

M0/M1 are shared with the Eve plan — the endpoint holder is byte-identical.

- **M0 — contract spike (no fork).** Prove the adapter shape against a stock
  celld by mapping an idfon-shaped synthetic request into a Worker's `fetch`
  over the existing HTTP listener (localhost). No celld changes. Reuses
  `docs/idfon-eve-channel-implementation-plan.md` M0.
- **M1 — endpoint holder.** `crates/idfon-eve-channel` (embeds `idfon-core`,
  owns the endpoint, UDS JSON IPC, `verify_message` + capability ticket).
  Identical to the Eve plan's M1; build once, use from both adapters.
- **M2 — celld iroh adapter (fork).** `crates/celld/iroh.rs`: bind the endpoint
  (M1's holder in-process, or the holder as a sidecar), decode+verify, and emit
  the request event into the actor mailbox so `logic` is untouched. Cell
  selection by addressed identity. Acceptance: an idfon peer messages a cell;
  the cell's `fetch` runs; the reply is delivered via `message.send`; a
  hibernated cell wakes with the correct lease.
- **M3 — media + streaming.** Blob tickets as file parts; live media as a
  stream ticket; `op_idfon_send`/stream ops modeled on `js/tcp.rs` for the
  cases the response body cannot carry.
- **M4 — HITL + identity granularity.** `input.requested` /
  `authorization.required` as request→response messages; decide and implement
  node-level vs per-agent identity.
- **M5 — agent-to-agent + hardening.** Per-peer isolation, loop/rate guards,
  and (if upstreamed) the generic ingress-adapter interface.
- **Later:** `idfon/mcp/1` on the same endpoint (tools axis, unchanged);
  managed-child packaging; per-agent keys.

Acceptance scripts follow the existing style (`scripts/eve-channel-*.sh`,
`PASS:`/`FAIL:`, non-zero on first failure). celld's GCS/S3 bucket can be a
local backend (`celld dev`) so the e2e needs no cloud.

## Open questions

- **Identity granularity** (above) — the one that most affects the shape.
- **Runtime fit** (above) — Worker/DO vs Node/Nitro.
- **Wake on message.** Does an inbound idfon message for a hibernated cell reuse
  the HTTP wake path verbatim, and does the reply wait for the lease?
- **Backpressure.** The message plane is discrete; the HTTP path is
  request/response. Confirm the adapter's event carries no streaming assumption.
- **Attestation.** In a split (holder sidecar) packaging, how does the adapter
  prove the peer identity to `logic` — signed frame or per-install secret, as in
  the Eve plan.
- **Relay/discovery.** Default iroh uses n0 relay + pkarr; a celld node may need
  a self-hosted relay, or must at least tolerate relay-only reachability.
- **Upstream appetite.** Whether denoland wants a generic ingress adapter or
  considers non-HTTP ingress out of scope (their scope note excludes "products
  that need the Cloudflare network").

## References

- `docs/idfon-eve-channel.md` — idfon as an ingress channel; the adapter shape.
- `docs/idfon-eve-channel-implementation-plan.md` — M0/M1, the shared endpoint
  holder.
- `docs/agent-conversation-plane.md` — the framework-agnostic bridge.
- denoland/celld — `README.md`, `docs/README.md`, `crates/celld/lib.rs`
  (actor/`on_event` mailbox), `crates/celld/js.rs` (isolate + ops),
  `crates/celld/js/tcp.rs` (outbound op precedent), `crates/celld/startup.rs`
  (listeners).
- `crates/idfon-core` (`transport.rs`, `lib.rs`) — endpoint, `serve`/`send`,
  `verify_message`, `verify_capability_ticket`.