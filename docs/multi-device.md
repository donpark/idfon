# Multi-device identity

How one person is represented across several idfon devices (iPhone + Mac),
why the current per-device identity model is not that, and the sequence of
changes that gets there.

> Status: design report, 2026-09-16. Supersedes the discussion notes
> `iroh-managing-ids.md`, `iroh-names.md`, and `iroh-multi-endpoints.md`
> (uncommitted scratch, now removed). Those notes are generic Iroh analyses;
> this one is idfon-specific and grounds every claim in the code.

## 1. Problem and constraints

**Requirement.** The same human uses the iOS app and the macOS app. Contacts
and state should follow the person, not the machine: a message sent to "Alice"
should reach Alice on whichever of her devices is up, and adding a laptop
should not require every peer to add a new contact.

**Constraints, in order of how much they constrain the design:**

1. **The iPhone must work when the Mac is off.** No always-on home node. If the
   Mac daemon happens to be the only place a key lives, that is a
   single-point-of-failure, not an architecture.
2. **The iOS daemon is in-process and freezes when the app backgrounds.**
   `AppDelegate` → `DaemonBootstrap.start()` runs `idfond` on a background
   thread that lives only while the process does (`docs/ios-architecture.md`).
   A frozen phone is **not a listener**. Any design that assumes the phone
   answers a dial in the background is wrong.
3. **Both devices are writers.** Two devices can be online at once, each
   sending and mutating state. No single-writer assumption survives.
4. **Peers are manually added.** idfon has `peer add` / ticket / `-pair`, no
   public directory. Cold discovery is a *future* problem; do not build for it
   now.

## 2. What idfon has today

The current model is **one identity = one Iroh key = one Endpoint**, and
multiple identities run concurrently:

- `Identity { id, name, public_key, endpoint_id, active }`
  (`crates/idfon-protocol/src/lib.rs`).
- `ensure_identity_keys` writes `identity-<id>.key` (0600) under the data dir;
  the key is the transport key. `TransportManager` holds
  `HashMap<identity, Arc<IrohTransport>>` and `add_identity` binds a fresh
  endpoint with that key (`crates/idfon-core/src/transport.rs`).
- Daemon startup binds `default` plus every other identity, then spawns a
  receiver, MCP inbound relay, and gossip rooms **per identity**
  (`crates/idfon-daemon/src/lib.rs`).
- Client IPC is a **Unix socket only** (`crates/idfon-client/src/lib.rs`);
  there is no remote/over-iroh daemon access.
- The daemon owns keys, state, and delivery durability through the sender's
  retrying operation queue, and outlives clients (`docs/daemon.md`).

**Consequence:** iOS and macOS each run their own daemon, with their own
`identity-default.key` and `state.json`. Same name, different keys, unrelated
state. "Alice on Mac" and "Alice on iPhone" are two unrelated peers to everyone,
including Alice. That is *not* multi-device; it is two devices that share an
owner.

Two smaller properties matter for what follows:

- **State is half event-sourced.** `events` have a monotonic per-identity
  cursor; `operations` carry an `operation_id` and an `idempotency_key`.
  But `peers`, `grants`, and `identities` are mutable structs overwritten in
  place, so mutations are not yet representable as a replayable log.
- **Peers are endpoint-shaped.** `Peer { id, identity, name, endpoint_id,
  endpoint_addr, aliases, call_mode }` — dial paths, invites, tickets, and
  live-call setup all resolve to an Endpoint. This is the load-bearing
  assumption that has to change.

## 3. Two axes, often conflated

These are inverse problems and idfon has both; only the second is new:

- **Profiles per device** — work / family / agent contexts on one machine.
  This is the current model, documented in `docs/daemon.md` and
  `docs/communication-model.md`. The old `iroh-multi-endpoints.md` note was
  about this axis (battery cost of N live endpoints on mobile).
- **Identity across devices** — one context spanning several machines. This is
  the axis this report is about.

They compose: eventually "work identity on both Mac and iPhone" is one context
across two devices, and the pair-per-device multiplication is real. But the
building block is the second axis.

## 4. Core model

### Account identity vs device endpoint

Introduce a second, app-layer keypair — the **account** — that is *not* the
transport key:

```text
account keypair (app-layer, signing only; never an Iroh Endpoint)
        │  signs
        ▼
signed device set: { EndpointId_A, EndpointId_B, … }
        │  each device still
        ▼
device transport EndpointId (its own key; never shared/copied)
```

- The **account id** is the stable handle contacts refer to. It outlives any
  device.
- Each device keeps its **own** transport key and endpoint, as today.
- The account key's sole jobs: sign device bindings, sign the device set, and
  (optionally) sign account-level state. It is a signing key, not a network
  identity.

**Why the account key must never be bound to an Iroh `Endpoint`:** the
"duplicate active key" failure mode (relay confusion, Pkarr thrash, split-brain
routing) only applies to keys that run endpoints. Keeping the account key out
of the transport layer makes that whole class of problem inapplicable, and
keeps the authority separate from any revocable device.

**Why not just share the transport key across devices:** the second you have
a Mac and an iPhone online together — which for this user is always — you get
exactly the relay/Pkarr conflict and split-brain QUIC handshakes. Never copy a
transport key. Linking a device **issues a new device key**, always.

**Status:** the account/endpoint key split is implemented. New identities use a
dedicated `endpoint-<id>.key` for transport and the identity key for account
signing. Existing endpoint bindings remain stable. Account-addressed peers,
device metadata, sender delivery policy, standard contact tickets, and
endpoint-aware calls are implemented.

### Account-addressed peers

`Peer` gains an `account_id` and a `devices` list. Dialing a peer means
resolving the account to a live device set and trying those endpoints, not
holding one `endpoint_id`. This is the expensive change: it touches the peer
record, `peer.add`, grants (`CapabilityGrant`/`CapabilityTicket` are keyed by
peer subject), invites, tickets, MCP contact tickets, and every dial path.

Do this first. It is the change that determines whether the account key is a
clean addition or a bolt-on to endpoint-shaped assumptions.

### Grants and fan-out

Grants are issued against a peer (account), not a device, and must hold across
the account's devices. Inbound envelopes need an **account-level id** so that
receipt on two devices, or neither, is recoverable: devices must tolerate
duplicates and the sender must be able to deliver to any one device. idfon's
room fan-out (`docs/chatrooms.md`) is the closest existing machinery.

### Discovery model today

A peer's device set is carried in the standard contact/device ticket and peer
record, distributed over the existing Iroh channel when a device is added or
updated. No DNS, WebFinger, or directory service is required by the prototype.

## 6. Sender durability and state sync (implemented)

Durability remains P2P by default. The daemon persists complete outbound
operations, including the signed envelope and delivery policy, in embedded
SQLite using WAL mode. Queued/transmitting operations can resume after daemon
restart and re-resolve current peer endpoints.

State mutations emit events. Devices exchange signed event batches over the
`idfon/sync/1` Iroh protocol. The receiving device verifies the account
signature, confirms the remote endpoint is enrolled for that account,
deduplicates event IDs, and applies supported snapshots deterministically.

This is a log-union prototype, not a CRDT. Blobs continue to use existing
tickets.

## 7. Push wake — deferred optional infrastructure

Push is not durability and is not required for P2P operation. The intended
production boundary is a `PushProvider` with no-op and local test
implementations, followed later by APNs/PushKit. Ordinary notifications would
wake the app to perform P2P sync; PushKit would wake CallKit-enabled calls.
Production work requires APNs credentials, device-token registration, provider
service deployment, token lifecycle handling, and real-device tests.

## 8. Public discovery — deferred

Manual standard contact/device tickets are sufficient for the prototype. Public
handles and directories remain future work. If needed, use authenticated
WebFinger/HTTPS rather than public DNS device graphs.

## 9. Mailbox/store-and-forward — deferred optional transport

A mailbox is intentionally not required. Pure P2P plus durable sender-side
operations is the default. Add an untrusted mailbox only if recipient-side
durability or delivery while the sender is offline becomes a product
requirement.

## 10. Enrollment and revocation

- **Enrollment** is out of band: the new device receives the account public key
  and a one-time bootstrap (QR). It generates its own transport key, proves
  possession, and the account signs `"device EndpointId X belongs to me"`.
- **Revocation** removes X from the signed device set. No account rotation, no
  coordination with the lost device.
- **Account rotation** happens only if the account key itself leaks.
- **Recovery:** an account with no recoverable device is an account lost.
  Either the account key is backed up (e.g. Keychain / recovery phrase) or the
  design accepts loss. Decide explicitly.

## 11. Lazy mobile binding (landed 2026-09-16)

The daemon now honours `IDFON_LAZY_IDENTITIES` (set by the iOS app): startup
binds and wires only `default` and the active identity, and `identity.use`
binds a switched-to identity on demand. Desktop is unchanged (all identities
bound concurrently). Guarded by the
`lazy_startup_binds_default_and_active_only` test.

## 12. Sequencing and status

1. Account/endpoint identity split — **implemented**.
2. Account-addressed peers and device operations — **implemented**.
3. Sender delivery policy — **implemented**.
4. Conversation authorization and deduplication — **implemented**.
5. Standard tickets and client pairing — **implemented**.
6. Calls and MCP endpoint selection — **implemented**.
7. Sender durability with embedded SQLite — **implemented**.
8. Signed event capture, merge, and Iroh sync — **implemented**.
9. Push wake — **deferred optional infrastructure**.
10. Public discovery — **deferred**.
11. Mailbox/store-and-forward — **deferred optional transport**, not a blocker.

## 13. Invariants

- A transport key is single-host and is **never copied**. Linking a device
  issues a new key.
- The account key is never bound to an Iroh `Endpoint`.
- Every account needs at least one recoverable device, or its loss is
  accepted.
- iOS is an **intermittent recipient**: anything that must arrive has to
  survive the phone being suspended indefinitely.

## 14. Open questions

- **One account per human, or per context?** Work/family contexts suggest per
  context; a single human handle would then need a layer above.
- **Who runs the mailbox?** Self-hosted, or a small managed service; and does
  it also cache blobs?
- **Cost model** for the untrusted service — storage, retention, and abuse
  handling.
- **Account recovery** UX (backup vs. accepted loss).
- Whether desktop should keep all identities live or also go lazy.

## Appendix — appraisal of the superseded notes

- `iroh-managing-ids.md`: correct key-hierarchy shape (per-device endpoints,
  signed bindings, revocation without master rotation). Overstates "separate
  Node processes" — distinct `Endpoint`s in one process suffice, which idfon
  already does. Hand-waves the two real costs: account addressing and merge
  semantics.
- `iroh-names.md`: right *shape* (signed handle directory) but solves
  cold/public discovery, which idfon does not have. Reusable later as
  WebFinger-with-auth; public DNS TXT is the wrong default for a private app.
- `iroh-multi-endpoints.md`: covers profiles-per-device, not
  identity-across-devices; useful for the lazy mobile binding and push pattern,
  wrong to present push as the durability story (that is the mailbox).
