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

## 5. Discovery — deferred

A peer needs the account's device set. Today that can be carried **in the peer
record**, distributed over the existing iroh channel when a device is enrolled
or a set changes. No DNS, no WebFinger, no directory service.

When idfon eventually grows public handles, resolve `handle → account key →
signed device set` via **WebFinger / HTTPS with authentication**, not a public
DNS TXT record: a public device set is a metadata graph that links one person's
endpoints, which is precisely the correlation the privacy model should avoid.

## 6. Delivery durability — the mailbox

This is the part neither the removed notes nor the general Iroh material
supplies, and it is the blocker.

Push is **latency, not durability**. A message "delivered" by waking a phone
is lost if the phone is off, the app was uninstalled, APNs drops it, or the
sender quits before the phone next foregrounds. Today, durability lives in the
**sender's** operation queue (`docs/daemon.md`); with a freeze-prone recipient
that is no longer enough.

Design:

- An **untrusted store-and-forward mailbox**, keyed by account id. Envelopes
  are opaque and signature-verified by the reader; the server cannot forge
  membership or read content.
- A device **claims** envelopes when it is next up (foreground, or woken).
  Claim is idempotent; duplicates are tolerated.
- Large media stays out of the mailbox: the mailbox holds envelope/signal
  data and blob *tickets*; blobs keep using the existing blob store, with the
  mailbox optionally caching for offline peers.

The mailbox is a server, and that is an honest cost for this requirement. A
suspended iOS app cannot be reached by pure P2P, and a phone that is off
cannot be reached by anything. The cheapest structure that satisfies
"iPhone works when Mac is off" includes one small, untrusted service.

## 7. Wake — push, last

Once the mailbox exists, push notifications are a latency optimization:
APNs/PushKit wakes the app briefly to drain the mailbox and, for calls, to ring
via CallKit (Pattern A signaling). Not built today (`docs/callkit-integration.md`).
Push requires a server that knows device tokens; that is the same service as
the mailbox, or a sibling of it.

Order matters: mailbox first (stop losing messages), push second (make them
arrive sooner).

## 8. State sync

State must converge across devices that were independently offline. idfon is
already half event-sourced, so the native approach is a **log union +
deterministic replay**, not a CRDT dependency:

1. Convert mutations of `peers`, `grants`, and `identities` into events. Until
   then there is no log to union.
2. Sync = exchange events/operations since the last common cursor, dedup by id,
   replay deterministically. This reuses the existing `events`/`operations`
   shapes.
3. Adopt `iroh-docs` only if the merge requirements outgrow a log (they do not,
   at idfon's current scale).

Device-to-device sync itself runs over iroh, authorized by the account-signed
device set. Blobs sync via the existing store/tickets.

## 9. Enrollment and revocation

- **Enrollment** is out of band: the new device receives the account public key
  and a one-time bootstrap (QR). It generates its own transport key, proves
  possession, and the account signs `"device EndpointId X belongs to me"`.
- **Revocation** removes X from the signed device set. No account rotation, no
  coordination with the lost device.
- **Account rotation** happens only if the account key itself leaks.
- **Recovery:** an account with no recoverable device is an account lost.
  Either the account key is backed up (e.g. Keychain / recovery phrase) or the
  design accepts loss. Decide explicitly.

## 10. Quick win, independent

`crates/idfon-daemon/src/lib.rs` binds **every** identity's endpoint at
startup, mobile included. On iOS those endpoints all die on the next
background anyway, so this is pure cost. Lazy-bind only the active identity on
mobile; leave desktop concurrent. Small, no new infrastructure, correct given
the freeze.

## 11. Sequencing

1. **Account-addressed peers** (schema + protocol + dial paths). Load-bearing.
2. **Account key + signed device bindings + out-of-band enrollment.** Device
   set rides the peer record — no discovery service.
3. **Mailbox** for durability.
4. **Device-to-device state sync** (after mutable state is event-sourced).
5. **Push wake**, then **discovery**, as they become necessary.

## 12. Invariants

- A transport key is single-host and is **never copied**. Linking a device
  issues a new key.
- The account key is never bound to an Iroh `Endpoint`.
- Every account needs at least one recoverable device, or its loss is
  accepted.
- iOS is an **intermittent recipient**: anything that must arrive has to
  survive the phone being suspended indefinitely.

## 13. Open questions

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
