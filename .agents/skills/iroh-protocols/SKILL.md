---
name: "iroh-protocols"
description: "Project-specific Iroh protocol-layer cheatsheet and implementation guide for idfon. Use when designing, debugging, or explaining Iroh networking, raw messaging, streams, datagrams, ALPN application protocols, discovery/relay, gossip, services, blobs, docs, live streaming, tickets, or the JS/native bindings."
version: 2
created: "2026-08-27"
updated: "2026-09-02"
---
# Iroh Protocols

## Core mental model

Iroh is a networking toolkit, not a generic application messaging protocol. The usual stack is:

```text
application semantics and payload format
  └─ your ALPN-selected protocol (or an iroh-* protocol)
       └─ QUIC streams and/or QUIC DATAGRAM frames
            └─ Iroh endpoint/networking (endpoint IDs, discovery, relay, hole punching)
                 └─ UDP/IP (with platform/network path details)
```

A useful rule: **Iroh transports bytes; the application defines what those bytes mean.** A `write()` or `writeAll()` sends bytes into a stream. It does not create a typed message, JSON object, or message boundary.

## Layer cheatsheet

| Layer / protocol | Provides | Choose it when | Does not provide |
|---|---|---|---|
| UDP/IP | Reachability and packets | You are reasoning about paths, NAT, MTU, or firewalls | Reliability, encryption, peer identity |
| QUIC transport | Encrypted connections, ordered reliable streams, flow control, multiplexing, optional unreliable datagrams | You need transport primitives | Your application message schema |
| Iroh endpoint (`iroh-net`) | Stable cryptographic endpoint identity, direct connections, relay fallback, discovery, hole punching | You need peer-to-peer connectivity across NATs | Pub/sub, durable storage, generic RPC, message serialization |
| ALPN | Negotiates/selects the application protocol during connection setup | You have a custom protocol or need protocol separation | Framing, authentication policy, payload encoding |
| QUIC bidirectional stream | Reliable, ordered byte stream in both directions | Requests/responses, commands, chat messages that must arrive, file/blob transfer | Message boundaries; application framing is required |
| QUIC unidirectional stream | Reliable ordered bytes in one direction | Server push, one-way transfer, logs/events | Reverse-channel replies |
| QUIC DATAGRAM | Unreliable, unordered, connection-scoped datagrams | Telemetry, presence, realtime state where newer data supersedes lost data | Delivery, ordering, unlimited size, persistence |
| Custom app protocol | Your schema, framing, auth, request IDs, errors, retries | The semantics do not fit an existing protocol | Automatic interoperability or delivery guarantees |
| `iroh-gossip` | Topic-based peer membership and best-effort dissemination | Ephemeral pub/sub, presence, collaborative fanout | Durable history, exactly-once delivery, a broker-like queue |
| `iroh-services` | Service-oriented request/response building blocks over Iroh connections | You want reusable service/RPC patterns rather than designing every control protocol from scratch | A universal message schema; service APIs still define their own requests and responses |
| `iroh-blobs` | Content-addressed immutable data transfer and local blob storage | Files, large messages, deduplication, resumable/reference-based transfer | Mutable records, chat ordering, generic RPC |
| `iroh-docs` | Higher-level replicated document/data synchronization built from Iroh primitives | Shared mutable collections/documents and eventual sync | Strongly consistent transactional database semantics |
| `iroh-live` | Higher-level real-time audio/video pipeline over Iroh/QUIC, currently using Media over QUIC (MoQ) with independent streams for tracks/renditions | Real-time audio/video capture, encoding, transport, decoding, playback, calls, rooms, or broadcast | Generic chat messaging, durable storage, arbitrary request/response; it is an early tech preview with changing APIs |
| Discovery services | Ways to find endpoint addresses/relay information | Bootstrap and connection establishment | Application authorization or message routing |
| Relay | A fallback path when direct connectivity fails | Connectivity through restrictive NAT/firewall | A pub/sub server or application mailbox |
| Endpoint tickets | Human/QR/shareable bootstrap encoding for an endpoint address | Passing connection information out of band | A protocol payload or proof of application permission |

`iroh-services`, `iroh-live`, and the exact wire protocol identifiers/APIs are especially version/repository-sensitive. Confirm their current crate documentation and source before treating this summary as a compatibility contract.

## Picking the right primitive

### Reliable one-to-one message or RPC

Use a bidirectional QUIC stream. Define a framing protocol, for example:

```text
u32 big-endian length | payload bytes
```

Then define the payload encoding separately (JSON, CBOR, protobuf, or a compact custom format). For multiple requests per connection, add request IDs and response/error frames, or open one stream per request. Finish a stream when using one-message-per-stream or EOF-delimited protocols.

A newline separator is acceptable only for bounded UTF-8 text that cannot contain an unescaped newline. It is not a general binary framing protocol.

### Realtime state / telemetry

Use QUIC DATAGRAM when loss and reordering are acceptable. Include a sequence number or timestamp if receivers need to discard stale updates. Bound datagram size and handle send failure. If every update matters, use a stream instead.

### Broadcast / pub-sub

Use `iroh-gossip` for ephemeral topic dissemination. Treat delivery as best-effort/eventual: persist important events elsewhere, make handlers idempotent, and design for duplicates, missing events, peer churn, and partitions.

### Large content or files

Use `iroh-blobs`: identify content by its hash/blob reference and transfer the content separately. Send a blob reference through a small control protocol rather than putting a large file inside an ad-hoc control message. Verify the expected hash and enforce size limits.

### Messaging

For one-to-one commands or request/response, use `iroh-services` when its service model fits, otherwise use a custom ALPN over bidirectional QUIC streams. The request and response types are still application-defined.

For ephemeral group chat or presence, use `iroh-gossip`; treat messages as bytes with best-effort/eventual delivery, possible duplicates, peer churn, and no durable mailbox guarantee. For durable chat history, store messages in an application database or replicated `iroh-docs` data model, and optionally use gossip as the low-latency notification path.

### Shared mutable data

Use `iroh-docs` when the problem is replicated document state rather than individual messages. Keep application authorization and conflict/business rules explicit; transport connectivity is not authorization.

### Audio / live media

`iroh-live` can remove the need to design an RTP/QUIC media path yourself. Its current project describes a higher-level pipeline covering capture, encoding, Iroh/QUIC transport, decoding, and rendering, with Opus audio and Media over QUIC (MoQ). It uses independent QUIC streams for tracks/renditions so video loss does not block audio. It is an early tech preview with frequent API changes and unreleased dependencies, so verify the current source and platform support before adopting it.

You still need Idfon's own control and permission model around it: who may publish, who may subscribe, whether playback is automatic, and how sessions are started or revoked. Use `iroh-blobs` separately for completed recordings and replayable audio.

### Custom ALPN checklist

For a custom protocol:

1. Pick a stable, versioned ALPN such as `com.example.product/control/1`.
2. Configure the same ALPN on both endpoints and reject unexpected protocols.
3. Decide stream ownership and lifecycle: one stream per request, long-lived stream, or separate control/data streams.
4. Define framing; never rely on one `write()` equaling one read.
5. Define encoding, maximum frame/message size, malformed-input behavior, timeouts, cancellation, and backpressure.
6. Define identity and authorization. Knowing an endpoint ID or possessing a ticket is not automatically application authorization.
7. Decide whether retries can duplicate operations; use idempotency keys where needed.
8. Add compatibility/version behavior before changing the wire format.

## Current-repo translation

In this repository's examples:

```js
const ALPN = Array.from(Buffer.from('hello-iroh/0'))
const bi = await conn.openBi()
await bi.send.writeAll(Array.from(Buffer.from('hello')))
await bi.send.finish()
```

`hello-iroh/0` is the negotiated application protocol identifier. `hello` is just UTF-8 bytes written to a reliable bidirectional QUIC stream. The echo behavior is application code, not an Iroh messaging service.

The native UI currently packages its host command as:

```text
<receiver-address>\n<message>
```

That is an in-process TypeScript-to-Zig command format. Zig removes the address and writes only `<message>` to the Iroh stream.

## Project lessons (idfon daemon)

Earned from debugging the real daemon; each one cost a session:

- **Idempotency keys must outlive the client.** The daemon dedupes persisted operations on `(target, idempotency_key)`. GUI keys once derived from chat history length reset on every app restart and collided with operations persisted across sessions: different content → `idempotency_key_conflict` (send silently rejected); same content → stale op returned as `delivered` without sending. Keys must be unique over the daemon's lifetime of persisted operations, not the client session. The dedup is correct by design — fix the client key generation.
- **One failed inbound handshake must not kill the receiver.** A single timed-out inbound connection used to terminate the daemon's entire receiver loop. Handshake failures are now logged and skipped: accept-loop errors are per-connection, never process-fatal.
- **Accept-path handshake aborts are background noise, not bugs.** `Endpoint::accept()`/`Incoming::accept` failures such as `PROTOCOL_VIOLATION … authentication failed` or `timed out` look alarming but are documented expected behavior (see iroh's own doc on `Incoming::accept`, `endpoint/connection.rs`): the QUIC socket listens on a public UDP port and receives unsolicited datagrams — scanners, misdirected packets, other apps' traffic — that abort handshakes mid-way. Iroh's stated guidance is to log and continue. Symptoms that confirm noise vs. a real problem: intermittent, uncorrelated with specific messages, alternating failure reasons, and all sends still reaching `Delivered` (sends retry). Do not burn a session root-causing these from logs alone; the log line should say "background UDP noise" so future readers don't chase it.
- **Capability tickets, not endpoint possession.** `capability.ticket` issues signed tickets carrying issuer, optional subject, capabilities (`message.receive`), expiry (RFC3339), ticket ID, and revocation. Incoming messages validate issuer, subject, capability, expiry, and revocation when a ticket is presented; legacy no-ticket messages still pass for compatibility. Parse expiry per format — never lexicographically compare RFC3339 strings against Unix-second values (this bug shipped and was caught only by added tests).
- **Profile isolation for multi-instance testing.** Two identities on one machine is test-only: each instance runs its own daemon via `IDFON_PROFILE` (separate socket + data directory, `native/run-profile.sh <name>`). Launch scripts and IPC must agree on the profile paths, or the GUI silently lands on the wrong daemon.
- **Stale locks masquerade as transport failure.** A crashed daemon leaves `state.lock` (dead PID) and a socket file with no listener; both block startup and surface as `daemon_unavailable` — which looks like an Iroh problem but isn't. `DataLock::acquire` records the holder PID and takes over when it is dead; stale sockets are removed before bind.
- **Log the actual daemon response.** The decisive debugging move was FFI-level tracing of idfond request/response bodies (`/tmp/idfon-<pid>.log`); the daemon's real error was visible immediately, while static analysis of client code was inconclusive. When state matters, compare timestamps/endpoint IDs in `state.json` to pin which operations are new versus old.
- **App envelopes ride the message path.** Control payloads are versioned `\nkey=value` text envelopes sent as ordinary messages, dispatched by prefix before chat display: `IDFON-LIVE/1` (`action=start|stop`, `ticket=`) for live-call invitations, `IDFON-RECORDING/1` (`id=`, `codec=`, `sample_rate=`, `duration_ms=`, `sender_id=`, `ticket=`) for recording attachments. Live audio additionally requires an explicit GUI→daemon authorization handshake (peer identified as byte array) before local media starts — the daemon owns the media session, the GUI only requests it.

## Debugging questions

When a payload does not arrive, inspect in this order:

1. Did both endpoints bind and advertise the same ALPN?
2. Did discovery/ticket parsing produce the intended endpoint address and peer ID?
3. Did `connect`/`accept` succeed, including relay fallback?
4. Did the correct stream direction get opened/accepted?
5. Is the reader waiting for EOF while the sender forgot to finish the stream?
6. Is the application framing parser waiting for bytes that were never sent?
7. Did a size limit, timeout, cancellation, or backpressure condition terminate the operation?
8. If using datagrams/gossip, is the code incorrectly assuming reliable ordered delivery?

## Verification habit

Before implementing, inspect the exact package/crate version and source for the selected API and protocol. For nontrivial framing or parsing, leave one small runnable test covering a valid frame plus a malformed or truncated frame. Keep custom protocol code minimal, but do not omit trust-boundary validation or size limits.