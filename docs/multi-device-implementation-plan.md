# Multi-device implementation plan

## Status

Core prototype phases are complete through authenticated device-to-device state
sync. Remaining work is intentionally deferred infrastructure: production push
wake and public discovery. Mailbox/store-and-forward is not required for the
P2P prototype and is deferred unless sender-side durability proves insufficient.

Implementation rule: commit each phase separately. Update implementation docs
only after the planned phases are complete.

## Invariants

- Account IDs identify logical peers and conversations.
- Endpoint IDs identify concrete devices and remain valid for direct or
  ephemeral communication.
- A conversation is an account participant set. A 1:1 chat has two account
  participants; a room has more.
- Topics are transport/synchronization metadata, not conversation identity.
- The sender chooses delivery targets. Endpoint metadata guides policy but is
  not itself an authorization boundary.
- A logical message keeps one message ID across endpoint copies; receivers
  deduplicate by logical message identity.
- Pure P2P is the default. No mailbox or push service is required for ordinary
  delivery.

## Completed phases

### 1. Account and endpoint identity separation

- New identities have a signing-only account key and a separate endpoint key.
- Existing endpoint bindings remain stable.
- The account key signs messages and account-level authorization.
- The endpoint key is bound to one live Iroh endpoint.
- Mobile can lazily bind only the default and active identities.

### 2. Account-addressed peers and devices

- `Peer.id` identifies the logical account.
- Primary endpoint fields remain available for direct/primary delivery.
- Additional devices are represented by `Peer.devices`.
- Added incremental operations:
  - `peer.device.add`
  - `peer.device.update`
  - `peer.device.remove`
- Device metadata includes endpoint address, label, class, and capabilities.

### 3. Sender delivery policy

Supported delivery modes:

- `failover`: primary/matching endpoint until one succeeds;
- `one`: one matching endpoint;
- `all`: fan out the same logical message to all matching endpoints.

Policies may filter by endpoint ID or device class. Direct endpoint delivery
remains valid. Live calls reject fan-out and select one endpoint or fail over.
Room sends apply the policy independently to each account member.

### 4. Conversation delivery and authorization

- Direct chats and rooms use the same message, operation, event, and
  deduplication paths.
- Conversation identity is carried separately from endpoint routing.
- Message deduplication includes sender account, idempotency key, and
  conversation.
- Grants can be account-wide or conversation-scoped.
- Capability tickets can carry conversation scope and are signed over it.
- Inbound messages validate both account authorization and enrolled endpoint
  membership.

### 5. Standard tickets and clients

Canonical contact tickets carry:

```json
{
  "version": 1,
  "account_id": "...",
  "endpoint_id": "...",
  "endpoint_addr": "...",
  "label": "...",
  "device_class": "...",
  "capabilities": ["chat", "live_audio", "live_video"]
}
```

The ticket is used by CLI, Native, iOS, macOS, and MCP pairing. MCP contact
metadata requires an account ID; MCP is a service on an endpoint, not a type
of account.

### 6. Calls and MCP

- MCP authorization is account-scoped and validates the concrete endpoint.
- Live calls are endpoint-targeted by default.
- Calls can select a device or device class, but cannot fan out through the
  ordinary `all` policy.

### 7. Sender durability and state sync

- Outbound operations persist the complete envelope and delivery policy.
- Queued/transmitting operations resume after daemon restart.
- Embedded SQLite with WAL is enabled at `<data_dir>/state.db`; JSON remains a
  migration/human-readable export.
- State mutation events are recorded for identities, peers/devices, grants,
  and rooms.
- State events can be exported as account-signed batches.
- Iroh `idfon/sync/1` exchanges signed event batches between enrolled devices.
- Imported events are verified, deduplicated by event ID, and applied through
  deterministic snapshot mutations.

## Deferred phases

### Production push wake — optional

Push is a wake/latency optimization, never the source of truth or durable
storage. The intended abstraction is:

```text
PushProvider
├── NoopPushProvider       // current P2P default
├── LocalPushProvider      // tests/development
└── ApnsPushProvider       // production
```

For ordinary messages, APNs may wake the app so it can use P2P sync. For calls,
PushKit must immediately feed CallKit when that mode is enabled. Production
work still requires APNs credentials, device-token registration, provider
service deployment, token revocation, and PushKit/CallKit integration.

### Public discovery — deferred

Manual contact/device tickets are sufficient for the prototype. If public
handles are added later, prefer authenticated WebFinger/HTTPS or another
privacy-preserving directory. Avoid public DNS TXT device graphs.

### Mailbox/store-and-forward — optional future transport

A mailbox is deliberately not required. It would break the pure-P2P default and
is unnecessary while durable sender-side queues meet product requirements.
Consider it only if recipient-side durability or delivery while the sender is
offline becomes mandatory. If added, it should be an optional untrusted
transport holding opaque signed/encrypted envelopes, not the canonical state
store.

## Testing requirements

Completed coverage includes:

- separate account and endpoint keys;
- lazy identity binding;
- peer device add/update/remove;
- endpoint and device-class delivery policy;
- message fan-out/failover semantics;
- conversation-scoped grants and tickets;
- restart-persistent outbound envelopes;
- SQLite snapshot survival;
- state event deduplication and signed sync batches;
- enrolled endpoint authorization.

Deferred tests:

- APNs provider contract and token lifecycle;
- PushKit-to-CallKit behavior on real iOS devices;
- public discovery privacy and authentication;
- optional mailbox retention and claim semantics.
