# Idfon Architecture Implementation Plan

## Status

Planning document. This plan is intentionally written for review before implementation.

## Objective

Build Idfon as one local networking service with multiple clients:

```text
Idfon.app ─┐
idfon CLI ─┼─ local IPC ── idfond ── idfon-core ── Iroh
custom app ┘
```

- `idfon-core`: reusable Rust domain and transport functionality.
- `idfond`: long-running daemon that owns active endpoints, identity keys,
  connections, operations, and event delivery.
- `idfon`: thin, agent-friendly CLI client.
- `Idfon.app`: GUI client that owns local UX policy and media presentation.
- Custom apps: scoped clients of the same local API.

The primary public contract is the logical CLI/API, not Iroh, QUIC, or a
Rust dynamic-library ABI.

## Design principles

1. **One endpoint owner.** `idfond` owns live endpoint instances and private
   identity keys. Clients do not independently start networking for the same
   identity.
2. **Intent over transport.** Expose `send`, `fetch`, `events`, and `live
   invite`, not streams, datagrams, ALPNs, or blob providers.
3. **One logical API.** CLI, GUI, custom apps, and Rust clients use the same
   operation model.
4. **Obvious first guesses.** An agent should be able to infer common commands
   from the desired outcome.
5. **Structured by default for automation.** Stable JSON, JSONL, error codes,
   operation IDs, cursors, and exit statuses are part of the contract.
6. **Safe retries.** Effectful operations support idempotency keys and expose
   durable status.
7. **Explicit authorization.** Connectivity, identity, capability, and local
   UX policy remain separate decisions.
8. **Future-compatible addressing.** `--to` and peer resolution must support
   local aliases, endpoint IDs, tickets, and named endpoints without changing
   normal commands.
9. **Small initial surface.** Add a command only when it makes a real common
   task clearer.

## Proposed repository layout

```text
crates/
  idfon-core/       # domain types, identity, transport, operations, events
  idfon-protocol/   # versioned IPC/API request and response types
  idfond/           # daemon and local IPC server
  idfon-cli/        # thin command-line client
```

The existing Native SDK application becomes a client of `idfond`. A narrow
Rust C ABI or dynamic library may be added for Zig integration where needed,
but it must not become a second endpoint owner.

## Public concepts

The API should expose only the concepts clients need:

- `identity`: a named local cryptographic context;
- `peer`: a locally known or resolved remote party;
- `conversation`: optional communication scope;
- `message`: text or small logical content;
- `media`: recordings and other larger content;
- `operation`: durable receipt for work that can outlive a CLI process;
- `event`: observable state or incoming communication;
- `capability`: permission to perform a logical operation;
- `session`: scoped access for a registered custom app;
- `cursor`: durable event-stream position.

Transport concepts such as endpoint, connection, stream, ALPN, relay, and blob
provider remain implementation details except under `idfon debug`.

## Canonical CLI surface

The initial surface should be:

```sh
idfon context
idfon status

idfon identities
idfon identity use NAME

idfon peers
idfon peer show REF
idfon peer resolve REF
idfon peer status REF

idfon send --to PEER --text TEXT
idfon send --to PEER --file PATH
idfon fetch RESOURCE --output PATH

idfon events --follow
idfon wait --for EVENT

idfon operation get OPERATION_ID
idfon operation wait OPERATION_ID

idfon access check --to PEER --capability CAPABILITY
idfon access grant ...
idfon access revoke ...

idfon session info TOKEN
```

Useful aliases may include `idfon peer list`, `idfon identity list`, and
`idfon events`, but documentation should emphasize a small, consistent common
path.

Every command must provide:

```sh
idfon COMMAND --help
idfon COMMAND examples
idfon COMMAND schema
idfon COMMAND errors
```

Help must state purpose, usage, side effects, required capabilities, wait and
retry behavior, examples, input schema, output schema, and stable error codes.

## Input and addressing rules

Simple operations use flags:

```sh
idfon send --to alice --text "hello"
```

Complex operations accept JSON from stdin:

```sh
idfon send --json < request.json
```

All addressed operations use `--to`. The daemon resolves the reference. Future
forms may include:

```text
alice
alice@work
endpoint:abcd...
ticket:...
name:alice.example
```

Resolution must never silently choose an ambiguous result. Return an
`ambiguous_peer` error with qualified choices and a next-step hint.

Identity selection is explicit when needed:

```sh
idfon --identity work send --to alice --text "hello"
```

Every mutation result reports the identity and resolved target actually used.

## Request and result contract

Local IPC and CLI adapters use one logical request model:

```json
{
  "id": "req_1",
  "method": "message.send",
  "params": {
    "to": "alice",
    "content": {"type": "text", "text": "hello"}
  }
}
```

Success envelope:

```json
{
  "id": "req_1",
  "ok": true,
  "operation": "message.send",
  "result": {
    "operation_id": "op_123",
    "status": "accepted",
    "message_id": "msg_456"
  }
}
```

Failure envelope:

```json
{
  "id": "req_1",
  "ok": false,
  "operation": "message.send",
  "error": {
    "code": "peer_offline",
    "message": "Peer 'alice' is unreachable.",
    "retryable": true,
    "retry_after_ms": 5000,
    "next": ["idfon peer status alice"]
  }
}
```

CLI rules:

- `--json` emits one JSON document on stdout;
- `--jsonl` emits one document per event/result;
- diagnostics and logs go to stderr;
- failures use nonzero exit status;
- prose is never required for machine branching;
- binary content goes to an explicit output path or explicit `--stdout`.

## Operations and retries

Any work involving networking, remote acknowledgment, media transfer, or
another process gets an operation ID. Operations persist across CLI and daemon
restarts where practical.

Initial states:

```text
accepted → resolving → connecting → queued → transmitting → delivered
                                                        ↘ failed
```

Also support `cancelled` and `expired` where applicable.

Effectful commands accept `--idempotency-key`. Repeating a request with the
same key returns the original operation/resource rather than duplicating the
remote effect.

> **Client note:** keys must be unique across restarts, not just within one
> GUI session — see *GUI sends rejected with `idempotency_key_conflict`* in
> `docs/troubleshooting.md` for a concrete failure caused by session-local
> keys colliding with persisted operations.

Waiting is explicit and bounded:

```sh
idfon send --to alice --text hello --wait --timeout 10s
idfon operation wait op_123 --timeout 30s
```

## Events and resumability

Events are first-class daemon data, not log parsing:

```sh
idfon events --type message.received --peer alice --after CURSOR --jsonl
```

Event envelope:

```json
{
  "event_id": "evt_123",
  "cursor": "cur_456",
  "type": "message.received",
  "timestamp": "2026-08-29T12:00:00Z",
  "identity": "work",
  "data": {}
}
```

Cursors are the primary resume mechanism. A one-shot wait avoids requiring an
agent to implement a subscription loop:

```sh
idfon wait --for message.received --peer alice --timeout 60s
```

## Security model

`idfond` is the trust boundary for local Idfon state.

- Private keys never appear in argv, environment variables, session tokens, or
  context files.
- The daemon alone accesses identity stores and owns active endpoints.
- Local IPC uses a protected Unix domain socket initially.
- Every request is checked against identity, peer, conversation, capability,
  expiration, revocation, and resource limits as applicable.
- Connectivity or possession of an Iroh ticket is not authorization.
- Custom-app sessions are opaque, short-lived, revocable, app-bound where
  possible, and scoped to identity, peer, conversation, and capabilities.
- The GUI remains authoritative for notification, interruption, playback,
  recording consent, schedule, and emergency stop.

## Implementation milestones

### Milestone 1: Contract-only foundation

Define and test Rust types for requests, responses, errors, events, cursors,
operations, identities, peers, capabilities, and sessions. Add golden JSON
fixtures and schema documentation.

**Done when:** the same examples can be serialized/deserialized by the CLI,
daemon, and test code; malformed and unknown inputs produce stable errors.

### Milestone 2: Daemon and local IPC

Implement `idfond` lifecycle, readiness, status, shutdown, request IDs, and
protected local IPC.

**Done when:** `idfon status` and `idfon context --json` work against a daemon,
and daemon-unavailable errors are structured and actionable.

### Milestone 3: Identity and peer management

Implement identity selection and peer records/resolution. Start with local
aliases, endpoint IDs, and tickets while preserving the future named-endpoint
resolver boundary.

**Done when:** identity and peer commands are deterministic, ambiguous
resolution fails safely, and no client creates duplicate endpoint ownership.

### Milestone 4: Agent-grade messaging

Implement `send`, durable operations, `--json`, stdin JSON, `--wait`, bounded
timeouts, dry-run, idempotency keys, and stable errors.

**Done when:** a message can be sent, retried safely, inspected after a CLI
restart, and tested without parsing human output.

### Milestone 5: Event delivery

Implement filtered JSONL events, durable cursors, replay, and one-shot `wait`.

**Done when:** an agent can stop and resume an event stream without losing or
duplicating events beyond documented delivery semantics.

### Milestone 6: GUI migration

Move `Idfon.app` communication onto the daemon API. Keep GUI-only policy and
media UX in the app.

**Done when:** GUI and CLI observe the same identity, peer, operation, and
event state.

### Milestone 7: Files, recordings, and live media — complete

Phase 7 is complete under the revised boundary: the daemon owns network media
sessions, resource transfer, blob providers, authorization, operations, and
events; the GUI owns local device access, playback, consent, and emergency
stop.

Phase 7 MVP now includes versioned media/resource/session contracts, a
persistent daemon-owned media registry, bounded resource put/fetch/delete and
GC operations, resource/session listing, BLAKE3 content hashes, and capability-
checked media session lifecycle. Resource bytes are bounded to 512 KiB because
control IPC is bounded; larger content uses the BlobTicket transfer path.

The media boundary deliberately separates concerns: the daemon owns network
media sessions, blob providers, resource transfer, authorization, operations,
and events; the GUI owns local microphone/speaker devices, playback, consent,
volume/mute, notifications, and emergency stop. Raw device samples do not pass
through the daemon IPC. Live-session creation must therefore receive an
explicit GUI media source/consumer bridge rather than opening the default
microphone implicitly. The extracted `idfon-media` crate provides explicit
publisher/subscriber and local-resource handles; GUI device access remains
process-scoped because raw samples do not cross daemon IPC.

Add file transfer and domain-specific recording/live commands only where their
lifecycle differs materially from ordinary messages.

**Done when:** large content uses the appropriate Rust/Iroh mechanism without
leaking blobs, streams, or tickets into the normal agent workflow.

### Milestone 8: Custom app sessions — remaining

Implement app registration, approval, scoped sessions, capability checks, and
session event subscriptions.

**Done when:** a registered app can operate through the same API while an
unregistered or over-scoped app is rejected.

### Milestone 9: Named endpoint resolution — remaining

Add named endpoint lookup behind the existing peer resolver and `--to` field.

**Done when:** normal CLI/API callers require no semantic changes and name
ambiguity, staleness, and authorization remain explicit.

## Verification strategy

Each milestone should leave one runnable check behind, without requiring a
large test framework initially:

- protocol serialization round trip plus malformed input;
- daemon readiness and unavailable-daemon behavior;
- peer resolution including ambiguity;
- idempotent send retry;
- operation persistence and state transitions;
- event cursor resume;
- capability denial and expiry;
- session scope enforcement;
- named endpoint resolution without authorization bypass.

Integration tests should use a fake or in-process transport where possible.
Iroh integration tests should separately verify endpoint discovery, connection,
framing, stream completion, size limits, timeout, and reconnect behavior.

## Review and audit questions

### API ergonomics

- Can an agent guess the common command from the desired outcome?
- Is every important input named consistently?
- Can help produce a valid example without external documentation?
- Are defaults visible in every result?
- Are side effects and required capabilities discoverable?

### Reliability

- Can a command distinguish accepted, queued, delivered, failed, and timed out?
- Can an agent safely retry after an ambiguous timeout?
- Are operation IDs and cursors durable across restarts?
- Are reconnect and duplicate-event semantics documented?

### Security

- Is any private key or unrestricted credential exposed to a client?
- Can a ticket be mistaken for authorization?
- Are capabilities checked on every operation?
- Can logout or revocation invalidate active sessions immediately?
- Can one local application impersonate another?

### Architecture

- Is there exactly one endpoint owner per identity store?
- Does the GUI use the same API as the CLI?
- Is the Rust core reusable without requiring a dynamic-library ABI?
- Are Iroh details absent from normal agent workflows?
- Can named endpoints be added without changing callers?

### Complexity control

- Is a new command necessary, or can an existing intent cover it?
- Is a new abstraction used by more than one real implementation?
- Can JSON/stdin, standard IPC, or existing Rust types handle the requirement?
- Is a dynamic library needed for an actual ABI boundary, or only assumed?

## Phase 0 architecture decisions

These decisions unblock implementation of the contract and daemon foundation.
They keep the first release small and preserve the normal `idfon` workflow.

1. **IPC framing:** use length-prefixed UTF-8 JSON frames over a protected Unix
   domain socket. The prefix is a fixed-width big-endian `u32`; each frame is
   exactly one request, response, or server event. JSONL remains a CLI output
   format, not the IPC framing format.
2. **Protocol versioning:** every frame includes `version: 1`. Unknown fields
   are ignored unless a method declares them meaningful; malformed JSON,
   invalid versions, unknown methods, and oversized frames return stable
   protocol errors. Additive fields are compatible; changed meanings require a
   new version.
3. **Frame limits:** reject IPC frames larger than 1 MiB. File and media bytes
   never travel through this control protocol; use resource references and a
   separate transfer path.
4. **Daemon ownership:** `idfond` is the sole owner of active Iroh endpoints,
   identity keys, remote connections, and network listeners. Clients do not
   create endpoints. A per-data-directory daemon lock prevents duplicate
   owners.
5. **Installation:** initially run `idfond` as a separately installed process.
   GUI bundling and supervision are deferred until the daemon contract is
   stable.
6. **Persistence:** use one embedded transactional store owned by `idfond` for
   identities, peers, grants, sessions, operations, idempotency records, and
   retained events. Private keys use a platform-secure storage boundary where
   available and never appear in protocol responses.
7. **Operation durability:** an operation is durable before its `accepted`
   result is returned. `accepted`, `queued`, `transmitting`, and terminal
   transitions are persisted before being reported. `timeout` is an observation,
   not a durable terminal state. Recovery resumes queued work conservatively and
   never assumes an interrupted attempt was delivered.
8. **Delivery meaning:** `delivered` means the remote Idfon protocol accepted
   and durably recorded the logical message. Transport connection success alone
   is not delivery. If that acknowledgment is unavailable, end at
   `remote_ack` and report the weaker guarantee.
9. **Retries:** transport retries are at-least-once and effectful operations
   require an idempotency key. Receivers deduplicate by sender identity plus
   key. Reusing a key with different content returns
   `idempotency_key_conflict`.
10. **Events:** delivery is at-least-once. Event IDs are immutable and clients
    deduplicate them. Cursors are monotonically increasing per identity;
    replay is bounded by retention, and an expired cursor returns
    `cursor_too_old` instead of silently starting at the present.
11. **Initial capabilities:** begin with `message.send`, `message.receive`,
    `voice_message.send`, `voice_message.receive`, `live_audio.publish`,
    `live_audio.subscribe`, `recording.fetch`, and `recording.retain`. Unknown
    capability names are rejected. Grants include identity, subject, scope,
    activation, expiration, revision, and revocation data.
12. **Authorization:** endpoint reachability, tickets, and endpoint IDs only
    bootstrap or authenticate transport; none grants application access.
    Inbound work passes peer, capability, scope, expiry, revocation, and limit
    checks before application handling. Unknown peers fail closed.
13. **CLI output:** human output is the default on an interactive TTY.
    `--json` and `--jsonl` are explicit machine modes. Non-TTY output defaults
    to JSON.
14. **Custom-app sessions:** initial launch sessions are opaque, short-lived,
    revocable, and one-time. Bind them to the registered macOS application
    identity where platform APIs permit it. argv handoff is an MVP limitation
    and must not contain secrets.
15. **Native SDK boundary:** do not add a general-purpose dynamic-library ABI
    during foundation work. The GUI uses the same daemon API as the CLI. Add a
    narrow C ABI only for a demonstrated SDK limitation, never for endpoint or
    identity ownership.

### Implementation gate

Milestone 1 is ready to start when these decisions are reflected in versioned
Rust protocol types and golden fixtures. The first implementation slice is:

```text
idfon-protocol → idfond IPC/status → persistent identity/peer store
               → daemon-owned endpoint → authenticated text send
```

Media, custom-app launching, named endpoint resolution, and prompt-generated
local policy remain deferred until operation, authorization, and event
contracts are exercised end to end.

## Decisions requiring explicit review

The following are deferred rather than blocking the foundation:

1. The exact embedded database and platform keychain adapter.
2. Daemon auto-start and GUI packaging/supervision.
3. Whether recovered queued operations retry automatically or require an
   explicit retry command.
4. Per-event-family ordering guarantees and retention durations.
5. The final macOS application identity mechanism for custom-app sessions.
6. Additional capability vocabulary needed by media and groups.

## Implementation status

The contract, daemon IPC, persistence, CLI query surface, authenticated
message envelope, selectable transports, application acknowledgment path, and
multi-identity endpoint routing are implemented. Phases 1–7 are complete under
the revised daemon-centered media boundary. Capability tickets provide
issuer-controlled signed capability claims for message delivery; legacy grants
remain supported for compatibility. The project is paused before **Phase 8:
custom app sessions** and **Phase 9: named endpoint resolution**.

Phase 1 is complete only when outgoing work has explicit durable transitions,
transport failures are bounded and retryable, idempotency survives restart, and
a real two-endpoint integration check proves message plus acknowledgment
exchange. The fake transport is test-only; production daemon startup uses the
Iroh transport explicitly.

Current implementation status: the protocol, signing, peer/capability checks,
persistence, fake transport, real Iroh stream, acknowledgment exchange,
unit-level localhost Iroh round trip, asynchronous operation execution,
bounded retries, cancellation, persisted endpoint-key binding, and daemon
process startup verification are complete. The process test verifies two
independent real-Iroh daemons start with distinct persisted endpoint identities
and respond over protected IPC. A full two-process message exchange remains an
integration-test enhancement once peer provisioning is exposed through the
public API.

### Validation snapshot

The current baseline passes the full Rust workspace tests, media tests, Native
SDK check and tests, the two-daemon process test, workspace compilation, and
`git diff --check`. Capability-ticket coverage includes signing, malformed
claims, tampering, issuance, persistence, revocation, subject scoping,
expiration, and issuer validation. RFC3339 expiration values are parsed as
timestamps and invalid values fail closed. The Native SDK model contract is
refreshed and unused model/message diagnostics are explicitly declared through
`viewUnbound`.

### Phase 1 guarantees

- `accepted` is persisted before a send result is returned.
- `queued`, `transmitting`, `remote_ack`, and terminal transitions are persisted
  before they are reported.
- A transport timeout is retryable and does not imply delivery.
- `delivered` requires a valid matching `MessageAck`.
- Reusing an idempotency key with different content returns
  `idempotency_key_conflict`.
- Receiver-side duplicate delivery returns a duplicate acknowledgment without
  creating a second message, operation, or event.
- Message and acknowledgment frames are bounded and versioned.
- Fake transport is available only to deterministic tests.

## Definition of a successful first release

An agent can perform this complete workflow without understanding Iroh:

```sh
idfon context --json
idfon peer resolve alice --json
idfon access check --to alice --capability message.send --json
idfon send --to alice --text "hello" --idempotency-key hello-1 --json
idfon operation wait OPERATION_ID --timeout 30s --json
idfon events --type message.received --after CURSOR --jsonl
```

The GUI performs the same logical operations through the daemon, and a future
named endpoint resolver can replace local peer aliases without changing this
workflow.

## Phase 6 implementation status

The first GUI migration slice is implemented. The Native SDK host now exposes a
narrow `idfond.request` command that uses protected Unix IPC with the daemon's
length-prefixed JSON protocol. The GUI requests daemon context during startup
and reports daemon availability through model state. The host bridge does not
access identity keys or create a new daemon endpoint.

GUI text, reply, peer, and event traffic now uses the daemon IPC bridge. The
Native host retains only the daemon IPC client and local media controls; direct
GUI Iroh endpoint, receiver, sender, reply, and channel code has been removed.
Incoming message events are cursor-polled through the compact daemon event
protocol and converted into GUI conversation state.

## Phase 5 implementation status

Authorization and local-policy foundations are implemented. Capability grants
can be created, checked, revoked, expired, and persisted. Incoming and outgoing
message operations enforce the relevant capability and fail closed for missing
or expired grants. Local policy records and deterministic `policy.dry_run`
decisions are available without transport or media devices. Policy decisions
remain local; remote parameters cannot override them.

The initial capability vocabulary is the one defined in the Phase 0 decisions.
Audit information is represented through the existing durable event stream.
The Native SDK GUI now exposes the local live-audio approval policy, shows its
current state, and blocks incoming live subscriptions unless auto-accept is
explicitly enabled. Emergency stop remains available independently. Full
persistent policy editing, schedules, recording-specific consent, and richer
structured diagnostics remain follow-up work for media and GUI integration.

## Phase 4 implementation status

Multi-identity and peer management now support persistent identity creation,
selection, and deletion safeguards, plus persistent peer add/remove operations.
Identity keys are generated and protected on creation. Peer records retain names,
aliases, endpoint IDs, and serialized endpoint addresses for future Iroh
resolution. Resolution remains deterministic and refuses ambiguous references.

The active identity cannot be deleted, and the final identity cannot be deleted.
Live endpoint rebinding is implemented for Iroh mode. `identity.use` binds the
replacement endpoint from the selected persisted key before swapping transport,
closes the previous endpoint, restarts the receiver loop through the transport
manager, and persists the new endpoint ID. Fake mode keeps its in-memory
transport and does not require endpoint rebinding.

## Phase 3 implementation status

The CLI exposes status, context, identities, peers, peer resolution, peer show,
peer status, identity selection, send, operation lookup/cancellation, events,
and wait. Machine-readable JSON and JSONL output are available, stdin request
parameters are accepted with `--stdin-json`, and built-in help, examples,
schema, and stable-error descriptions are available through the corresponding
help topics. Operation lookup and event wait requests accept bounded timeout
parameters.

The CLI remains intentionally small and uses the same logical daemon methods as
the GUI. Full command-specific schema generation and a richer argument parser
remain future improvements if the surface grows beyond these commands.

## Phase 2 implementation status

Event queries now support type, peer, and cursor filtering. The daemon supports
one-shot `wait` responses and length-prefixed follow-mode responses; the CLI
renders follow-mode events as JSONL and supports `--after`, `--type`, and
`--follow`. Event delivery remains at-least-once and clients should
 deduplicate by `event_id`.

The durable event store and cursor format are implemented. Events are retained
up to the configured bounded history, stale cursors return `cursor_too_old`,
`wait` blocks up to its bounded timeout, and follow mode advances its cursor so
already-delivered events are not repeatedly emitted. Delivery remains
at-least-once; clients deduplicate by `event_id`.
