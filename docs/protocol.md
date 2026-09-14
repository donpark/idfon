# Idfon Daemon JSON IPC Protocol

The contract between the idfond daemon and every frontend (CLI, iOS, Android,
desktop). Reference implementation: `crates/idfon-protocol` (types) and
`crates/idfon-daemon/src/lib.rs` (dispatch). Regression coverage:
`scripts/test-cli.sh`.

## Transport

Unix domain socket (path ≤ ~104 bytes: device sandbox paths fit, simulator
apps use short `/tmp` paths). Framing: 4-byte little-endian length prefix +
JSON body; one request frame expects one response frame (the daemon may send
multiple response frames for `events` with `follow: true` and for `wait`
while it holds the request until a match or timeout).

## Envelope

Request:

```json
{ "version": 2, "id": "cli-1", "method": "peers", "params": {} }
```

- `version`: `PROTOCOL_VERSION` (currently **2**; bump on any breaking shape
  change; daemons reject mismatched versions). Version 2 replaced the closed
  capability enum with open namespaced strings.
- `id`: client-chosen, echoed in the response.
- `params`: per-method (below). The daemon injects the session identity for
  any param that is absent — an explicit `null` defeats the injection (this
  was a real CLI bug); omit identity params entirely unless overriding.

Response:

```json
{ "version": 2, "id": "cli-1", "ok": true, "operation": "status", "result": { } }
```

Failure: `ok: false` with `error: { code, message, retryable }`. Error codes
include `invalid_request`, `capability_denied`, `cursor_too_old`,
`daemon_unavailable`.

## Methods

### Lifecycle

| method | params | result |
|---|---|---|
| `status` | — | `{ ready, daemon, protocol_version, identity: {id, name, active, public_key, endpoint_id}, ticket: [bytes] }` (ticket = endpoint addr ticket, JSON byte array) |
| `daemon.shutdown` | — | `{ shutdown: true }` |

### Identity

| method | params | result |
|---|---|---|
| `identities` | — | `{ identities: [{id, name, active, public_key, endpoint_id}] }` |
| `identity.create` | `{ name }` | `{ identity }` |
| `identity.use` | `{ name }` | `{ identity, active: true }` |
| `identity.delete` | `{ name }` | `{}` — rejected for the active or last identity |

### Peers

`ref` in every method matches peer id, name, alias, or endpoint id.

`call_mode` selects how a shell surfaces an incoming call for that connection:
`"bar"` (Live Activity Bar) or `"call_kit"` (CallKit). It defaults to `bar` on
`peer.add` when omitted, and any other value is rejected with `invalid_request`.
`peer.update` only changes it when the param is present. The auto-created
reciprocal peer always takes the default.

| method | params | result |
|---|---|---|
| `peers` | — | `{ peers: [Peer] }`; Peer = `{id, identity, name, aliases, endpoint_id, endpoint_addr, call_mode, ...}` |
| `peer.add` | `{ ref, id, name, endpoint_id, endpoint_addr, aliases, call_mode?, mcp_ticket? }` | `{ peer }` |

`mcp_ticket` (M3) is an MCP contact ticket; when present it fills any omitted
`id`/`endpoint_id`/`endpoint_addr`/`name` and caches the ticket's
`server/discover` result. See the MCP transport section.
| `peer.update` | same as add | `{ peer }` |
| `peer.remove` | `{ ref }` | `{}` |
| `peer.resolve` | `{ ref }` | live connection info |
| `peer.show` / `peer.status` | `{ ref }` | `{ peer }` / connectivity |

### Messaging

| method | params | result |
|---|---|---|
| `message.send` | `{ to, text, idempotency_key, capability_ticket?, retries? }` | `{ authenticated, message_id, operation_id, status: "queued" }` — returns immediately; delivery proceeds in the daemon (retries per `retries`), confirm via `operation.wait`. Sender needs a `message.send` grant for the peer (own daemon); the receiver needs `message.receive` for the sender. A successful send auto-establishes the local receive side of the reply path. |
| `message.receive` | — | receive-side helper used by the transport; not called by shells. |

The `wait`/`events` methods below are how received messages surface: a
`message.received` event with `data: { message_id, peer_id, text }`. Signaled
blob transfers ride the same path as text with an `IDFON-DATA/1` envelope
(`ticket=`, `size=` lines).

### Events

`events` are persisted per identity, FIFO, with monotonically increasing
`cur_<20 digits>` cursors, retained up to `EVENT_RETENTION`. The only event
type currently emitted is `message.received`.

| method | params | result |
|---|---|---|
| `events` | `{ follow?, after?, type?, peer? }` | `{ events: [Event] }`; Event = `{ event_id, cursor, type, timestamp, identity, data }`. `after` earlier than the oldest retained cursor → `cursor_too_old` error; empty-string `after` is allowed and means "from the start". `follow: true` streams responses as events arrive. |
| `wait` | same as `events` + `timeout_ms` (default 30000, max 300000) | blocks server-side, returns the first matching event, or `{ events: [] }` on timeout (success — not an error) |

### Operations

Async operations (message sends, transfers) are persisted with ids and
terminal statuses `delivered | failed | expired | cancelled`.

| method | params | result |
|---|---|---|
| `operation.get` | `{ operation_id, timeout_ms? }` | `{ operation: { status, ... } }` |
| `operation.wait` | `{ operation_id, timeout_ms? }` | polls server-side until a terminal status |
| `operation.cancel` | `{ operation_id }` | `{}` |

### Access (capabilities)

Grants live on the granter's daemon and gate that daemon's own side:
`message.send` = this daemon may send to the subject; `message.receive` =
this daemon may receive from the subject. Subjects are peer endpoint ids
(public keys), never names.

| method | params | result |
|---|---|---|
| `access.check` | `{ subject, capability }` | `{ allowed, identity, subject, capability }` |
| `access.grant` | `{ subject, capability }` | `{ grant }` |
| `access.revoke` | `{ subject, capability }` | `{}` |
| `capability.ticket` | `{ subject, capabilities: [..], expires_at? }` | `{ ticket }` (signed, subject-bound; a verified ticket satisfies the receive gate) |
| `capability.ticket.revoke` | `{ ticket_id }` | `{ ticket_id, issuer, revoked }` |

Capabilities are **open namespaced strings**, not a closed enum: the built-ins
are `message.send`, `message.receive`, `voice.message.send`,
`voice.message.receive`, `live.audio.publish`, `live.audio.subscribe`,
`recording.fetch`, `recording.retain`, and `mcp.transport`, but any dotted name
is accepted, so a provider can define its own without a protocol change.

### Invocation results

One shared vocabulary for the result of an invoked capability:

```json
{ "type": "text", "text": "..." }
{ "type": "render", "view": { } }
{ "type": "blob_ticket", "blob_ticket": "..." }
{ "type": "stream_ticket", "stream_ticket": "..." }
{ "type": "error", "message": "..." }
```

### MCP transport

User-side relay for the MCP transport binding. The daemon stays generic —
ALPN → configured local command, or peer bi-stream → local Unix socket — and
never parses MCP.

| method | params | result |
|---|---|---|
| `mcp.listen` | `{ to }` | `{ socket, peer, direction: "outbound" }` — opens `<data_dir>/mcp/<hash>.sock`, then splices the first local connection to the peer's `idfon/mcp/1` bi-stream. Requires an `mcp.transport` grant for the peer. |

Inbound `idfon/mcp/1` connections are spliced to the command in the daemon's
`IDFON_MCP_COMMAND` environment variable, provided the remote endpoint has an
`mcp.transport` grant. `idfon-mcp connect --uds SOCKET` is the stdio shim.

**Contact ticket (M3).** `idfon-mcp serve --contact` mints an
`McpContactTicket { transport, peer, discover? }` — the dial address, the peer
endpoint id, and a cached `server/discover` the bridge probed from the local
server. `idfon peer add --mcp-ticket <json>` adds the peer offline. The cached
`discover` is a hint only: refresh it with a live `server/discover` (respect
`ttlMs`/`cacheScope`), and treat `serverInfo` as unverified display data.

### Media (resources/blobs)

Content-addressed blobs stored daemon-side; the ticket is a bearer
capability valid immediately after `put` completes (no peer setup needed to
fetch).

| method | params | result |
|---|---|---|
| `media.resource.put` | `{ resource_id, bytes: [..], append, finish }` | `{ identity, resource_id, size_bytes, content_hash, blob_ticket }` |
| `media.resource.fetch` | `{ ticket/blob ticket ... }` | `{ bytes: [..], ... }` — chunked fetch |
| `media.resource.get` / `delete` / `gc` / `register` / `resources` | — | resource management |
| `media.live.publish` | `{ file, loop?, relay?, name? }` | `{ ticket, id }` — broadcast; ticket is a bearer capability |
| `media.live.dial` | `{ to, file, relay?, seconds? }` | 1:1 session; blocks until the callee hangs up; no ticket (session-scoped) |
| `media.live.answer` / `subscribe` | — | callee/subscription side |
| `media.live.publishers` | — | `{ publishers: [...] }` |
| `media.live.stop` | `{ id }` | graceful stop |
| `media.sessions` / `media.session.start` / `media.session.stop` | — | session registry |

### Policy

| method | params | result |
|---|---|---|
| `policy.set` / `policy.dry_run` | policy document | capability-policy evaluation |

## Versioning discipline

1. Adding an optional param or result field: no version bump; shells must
   ignore unknown fields.
2. Removing/renaming a field, changing a type or semantic: bump
   `PROTOCOL_VERSION` and update every frontend.
3. Every change to this document should come with a `test-cli.sh` (or
   e2e-script) assertion covering the changed surface.
