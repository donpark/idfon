# Idfon Chatrooms — Design

> **Status:** design, not implemented. Companion to
> `docs/communication-model.md` (group/broadcast modes) and
> `docs/agent-conversation-plane.md` (C3: thread by peer + explicit
> `conversation_id`). Written 2026-09-15.

## The answer in one line

**A room is a topic id.** No `Room` entity, no membership server, no protocol
version bump: a room reuses the signed `conversation` field already on every
`MessageEnvelope`, plus the `conversation` scope already on `CapabilityGrant`.
A 1:1 chat is the degenerate room (`conversation = None`), so both paths stay
one code path and one set of verbs.

## What already exists (reuse, do not rebuild)

| idfon primitive | room role |
|---|---|
| `MessageEnvelope.conversation: Option<String>` | the room id (topic); inside `auth_bytes`, so signed and tamper-proof |
| `CapabilityGrant.conversation: Option<String>` | per-room grant scope (who may post to *this* room) |
| `message.send` / `message.receive` grants | membership is enforced by grants, not by knowing the topic |
| `capability.ticket` (subject-bound, signed) | how a non-member is admitted to one room |
| `events` / `wait` (cursors) | room timeline per identity |
| peer id (endpoint key) | message author, verified per message |

A bare topic id is a *bearer capability*. idfon's grants are the authorization
layer on top — which is why the topic does not have to stay secret to be safe.

## What a topic id does not give you

Four gaps, named up front so they are not discovered late:

1. **Membership.** A topic has subscribers, not members. You still need a local
   member set: who to deliver to, who to show, whose revocation matters.
2. **Delivery.** `message.send` is strictly one peer (`to`). A room needs
   fan-out. `iroh-gossip` 0.101.0 is **already in the dependency tree**
   (transitive via `iroh-live` and `iroh-smol-kv`) and compiled into the
   vendored dylib with ALPN `/iroh-gossip/1`, but no idfon code uses it yet.
3. **Confidentiality.** Messages are signed but **not payload-encrypted**;
   QUIC/TLS protects each hop only. Until the shared-key work lands, privacy is
   an unguessable room id alone.
4. **History.** Pubsub is ephemeral; rooms need retention and late-join backfill.

## Model

### Room identity

The room id is an opaque string in `conversation`. Two kinds:

- **Open room** — a human-readable topic (`idfon:room:design`). Anyone may
  address it; grants still decide whether a given peer is *listened to*.
- **Private room** — 128-bit random id (`r_<32 hex>`). Unguessable, which is
  the entire privacy story in v1 (see Confidentiality).

No registration, no directory. Two peers share a room iff they agree on the same
string — the same property blob tickets have: the address is not the
authorization.

### Membership

Membership is **local state**, never a shared list:

```
Room { id, name?, members: [peer_id], grants: [...] }
```

You add a member by granting it `message.send` **scoped to that conversation**,
or by admitting it with a `capability.ticket` bound to the room. Divergent
member lists are expected: delivery is best-effort to *your* list, and nothing
breaks when two peers disagree about who is present.

### Delivery (v1: fan-out on the existing plane)

No new transport. The sender signs **one envelope per recipient** — same
`conversation`, distinct `idempotency_key`/operation — and sends each over
`idfon/message/1`.

- `O(members)` sends, each independently acknowledged and retried, so a partial
  failure is visible per recipient.
- Each message is signed by the author, so a recipient proves authorship without
  trusting the sender's daemon.
- No cross-recipient ordering; each recipient orders by its own event cursor.
  **Total order is not promised.**

`iroh-gossip` is the right transport at larger membership. It is **already in
the build** — transitive via `iroh-live` and `iroh-smol-kv`, present in
`Cargo.lock`, and linked into `mac/Vendor/libiroh_c_ffi.dylib` (ALPN
`/iroh-gossip/1`) — so adopting it is API work, not a new dependency. It is
still a new failure surface (tree maintenance, no acks, eventual consistency).
Defer it: fan-out is correct and testable for the small rooms that matter
first.

Note the identifier alignment: an `iroh-gossip` topic is itself a 32-byte id,
so the room id can *be* the gossip topic id. R2 becomes a transport swap under
the same identifier, not a re-addressing.

### Confidentiality — decided: shared room key

**Decision (2026-09-15): one symmetric room key per room.** Chosen over a
per-sender ratchet / MLS as the best cost-benefit at the room sizes idfon
targets.

Shape:

- **Key.** A random 32-byte `K` per room. Content is sealed with an AEAD
  (XChaCha20-Poly1305), one nonce per message.
- **Distribution.** `K` is wrapped to each member's public key (HPKE /
  sealed-box) and delivered as an ordinary peer message. Adding a member =
  wrap `K` to them; removing one = mint `K'` and re-wrap to the rest.
- **Wire.** Ciphertext rides the existing `Text` content as an `IDFON-ROOM/1`
  envelope (`nonce` + `ciphertext`, base64), matching the `IDFON-DATA/1` /
  `IDFON-LIVE/1` precedent — so **no protocol bump**. A `MessageContent`
  variant would be cleaner, but changing the type is a bump by the versioning
  discipline.
- **Signatures are unchanged.** The envelope is signed as today and only
  `content` is opaque (sign-then-encrypt), so `message.receive` still
  authenticates the author independently of the room key.

Accepted trade-offs, taken knowingly:

- **No forward secrecy.** A member who leaves still holds `K` and can read
  everything they recorded. Rotation stops *future* reads, not past ones.
- **No post-compromise healing.** If `K` leaks, traffic under `K` is readable
  until a rotation actually completes.
- **Members can read each other.** The room is a trust boundary, not a set of
  private channels.

Prerequisite (net-new): idfon identities are **Ed25519 signing keys only**
(`idfon-core`). Sealing needs key agreement, so the identity record must gain
an X25519 encryption key (or an Ed25519→X25519 conversion). Nothing above
works until that exists.

Rejected for now: **MLS / per-sender ratchet.** It buys forward secrecy and
consistent membership, but needs a delivery service that imposes total ordering
on the group — which v1 fan-out deliberately does not provide (see *Delivery*).
Not justified at the target room size; revisit if forward secrecy is required.

### History

Per-daemon local store keyed by `(peer, conversation)`. Late joiners get
**nothing** automatically; a member who wants to hand over history mints a blob
ticket (`IDFON-DATA/1`) for the room log and sends it like any attachment.
Retention is a product decision per room, not a protocol one.

## Wire shape

No protocol bump. A room turn is an ordinary envelope:

```json
{ "message_id": "…", "sender": { "peer_id": "…", "signature": "…" },
  "content": { "Text": { "text": "…" } },
  "idempotency_key": "…", "conversation": "r_3f9c…", "capability_ticket": null }
```

Shell surface (v1, additive; unknown fields stay ignorable):

| method | params | result |
|---|---|---|
| `room.create` | `{ id?, name?, members? }` | `{ room }` — generates a random id when omitted |
| `room.list` | — | `{ rooms: [Room] }` |
| `room.send` | `{ room, text, idempotency_key }` | `{ operation_ids: [...] }` — one per member |
| `room.leave` | `{ room }` | `{}` — local only |

`room.send` is sugar over N `message.send` calls. The daemon learns nothing
about rooms beyond a member list.

## The Eve agent seam

An agent joins a room the way a human does — it is a peer with a member list.
The channel address already has the right shape:

```
address = peer_id              (1:1,      conversation = None)
address = peer_id:conversation (threaded 1:1)
address = conversation         (room: N senders → one session)
```

Three 1:1-only assumptions in `integrations/eve-idfon-channel/extension/channels/idfon.ts`
must not survive:

1. **`sessionTargets` stores one peer.** A room session needs the member set, so
   a reply fans out to members instead of back to `target.peerId`.
2. **One session per peer id.** A room session is keyed by `conversation`, with
   several `peer_id`s feeding it.
3. **`sessionAuth` from one caller.** Eve sessions carry a single principal
   today, so per-participant identity rides on each message (the signed
   `sender.peer_id` / `auth`) and the room is session *scope*, not a
   session-wide principal.

This keeps the "no agent/human distinction" rule: the agent is a member, rooms
are how members talk, and the agent's ingress ticket remains its own policy.

## Milestones

Each step is independently useful and leaves no dead surface.

1. **R0 — fan-out text (no protocol change).** `conversation` and the grant
   scope already exist. Add a member list, `room.send` fan-out, and
   `--conversation` on the CLI send path. Acceptance: one prompt to three peers,
   all three receive the same room id.
2. **R1 — Eve channel rooms.** Key sessions by `conversation`, fan replies to
   members, keep the per-message principal. Acceptance: two humans + one agent
   in one room; both humans see the agent's reply.
3. **R2 — gossip transport.** Wire in the already-linked `iroh-gossip` for
   large rooms, keeping fan-out as the small-room path. Only if R0/R1 show
   membership sizes that need it.
4. **R3 — room confidentiality (shared key).** Add an X25519 identity key, the
   `IDFON-ROOM/1` sealed-content envelope, and key wrap/rotation on membership
   change. Acceptance: a room where an outsider who learns the topic id still
   cannot read content.

## 1:1 equivalence

A 1:1 chat is a room of two with `conversation = None`: same envelope, same
grants, same `message.send`. Nothing in R0–R3 should add a code path that only
rooms take, or only 1:1 takes.

## Open questions

- Should `conversation` be bound to the recipient, or is one shared topic id
  enough? (Today it is one shared field.)
- Who may add/remove members — any member, or an admin role? The communication
  model wants roles; v1 has none.
- Does a room need a stable display name, or is the id the name?
- Does `room.send` dedupe by `idempotency_key` per recipient or per room?

## References

- `docs/communication-model.md` — group/broadcast modes, grants, policy.
- `docs/agent-conversation-plane.md` — C3: thread by peer + explicit
  `conversation_id`.
- `docs/protocol.md` — `message.send`, grants, events, tickets.
- `docs/idfon-eve-channel.md` — the channel address model.
- `crates/idfon-protocol/src/lib.rs` — `MessageEnvelope.conversation`,
  `CapabilityGrant.conversation`.
