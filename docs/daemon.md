# Daemon rationale

Why `idfond` exists as a separate process, what it is responsible for, and —
just as important — what it deliberately does *not* do.

## The one-line model

The daemon owns **the network that exists even when no app is running**, and
the **state that many local agents must share safely**. Everything
interactive and ephemeral lives in the client (GUI, CLI); everything that must
outlive a client or be single-writer lives in the daemon.

## What the daemon earns

1. **Reachability that outlives apps.** Closing a window doesn't drop the
   persona offline; invites/messages/blob fetches still land. Idle-exit bounds
   the resource cost (see `IDFON_IDLE_EXIT_SECS`); `--keep-alive` pins it.
2. **Delivery guarantees for in-progress work.** Sends retry through the
   operation queue, event history is retained for later pickup (`recv`), and a
   send survives the initiating app quitting a second later.
3. **Key custody.** Identity keys live in the daemon store; local agents
   authenticate over the local socket and the daemon signs envelopes on their
   behalf. Agents never hold key material.
4. **Single-writer state.** Peers/grants/history/events/blobs with one lock
   domain. Multi-process alternatives are known-bad: two `FsStore`s on one
   `blobs.db` deadlock; two daemons on different data dirs split-brain.
5. **Blob serving while you're away.** Peers fetch content from your node on
   the daemon's listener; a transfer doesn't die because the sending agent
   closed.
6. **One IPC surface for every client shape** — CLI (stateless), macOS GUI
   (thin), iOS (in-process daemon, since iOS can't background). The daemon is
   embeddable; that's why iOS works.

## What the daemon deliberately does not do

- **No real-time media path.** Live audio/video capture, publish, subscribe,
  and decode run in the client process with client-owned iroh endpoints
  (`native/vendor/iroh-c-ffi/src/media.rs`); peers connect directly via live
  tickets. The daemon is signaling-only for calls.
- **No UI, no mediation of interactive traffic.** It is signaling + storage +
  liveness, thin by design.

## Multi-agent model ("why per-identity" — verified 2026-09-08)

Any number of local agents may use idfon at once. The split that makes this
scale:

- **Daemon (listening + in-progress + state):** one listener per identity,
  running concurrently — receiving, blob serving, queued/retrying sends,
  shared stores. These must outlive agents and be singletons.
- **Agents (interactive):** view state, event polling, live media — already
  direct, no daemon mediation needed.

**The daemon runs one endpoint per identity, concurrently.**
`idfon_core::transport::TransportManager` holds a
`HashMap<identity, endpoint>`; `send(identity, …)` routes through the sending
identity's own endpoint. Desktop startup binds `default` plus every other
identity. On mobile (`IDFON_LAZY_IDENTITIES`, set by the iOS app) startup binds
only `default` and the active identity — idle endpoints die on background
anyway — and `identity.use` binds a not-yet-bound identity on demand, wiring
its receiver, MCP relay, gossip, and rooms at that point. Daemon traces confirm
concurrent delivery for two identities in one daemon.

**Identity key vs endpoint key (2026-09-16).** A transport key must never run
on two live endpoints, so the identity key is being split from the endpoint
key: identities created since the split get a dedicated `endpoint-<id>.key`,
and the identity key (`identity-<id>.key`) becomes a signing-only *account* key
that signs envelopes and grants while the endpoint presents its own id —
`PeerAuth` already carries `peer_id` and `endpoint_id` separately. Identities
created before the split fall back to the identity key for both roles, so their
endpoint id — and every peer record pointing at it — is unchanged. See
`docs/multi-device.md`.

Client responsibilities under this model:

- A client connection carries a **session identity** (persisted `active`
  identity, overridable per request) used to default identity-scoped requests.
- GUIs that surface invites from the initial events drain must adopt the
  caller into their send target (`withInboundTarget`) and build idempotency
  keys that are unique across app relaunches (`${tickAt}-…`, not just
  history-length) — the daemon deduplicates operations forever and rejects
  reused keys with different content (conflicts are logged since 2026-09-08).

## The trade, stated honestly

If neither "the network exists when my apps don't" nor "many local agents, one
persona, no key/store contention" mattered — a single app, always open,
owning its keys — the daemon could be embedded and the IPC layer deleted. With
CLI + GUI + iOS clients and multiple local agents, those two properties are
the product, and the daemon is the cheapest structure that provides them.
