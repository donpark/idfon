# Idfon as an MCP Transport Binding

> **Status:** implemented — see `docs/mcp-implementation-plan.md` (M1–M5).
> Grounded in the Model Context Protocol specification revision **2026-07-28**
> (current as of 2026-09-13). Earlier revisions (through `2025-11-25`) were
> stateful and are not the target.

## The problem

MCP's only remote transport is Streamable HTTP. That means a remote MCP
server must be a publicly reachable web service with its own authentication —
URL, DNS, TLS, reverse proxy, OAuth or API keys — and a client that is
configured with that URL at startup. Adding one is static and internet-facing.

Idfon flips the address model: peers are cryptographic identities reached over
iroh (hole-punch + relay), with no public endpoint and no directory, and
access is governed by grants rather than OAuth tokens. MCP assumes a known,
reachable URL; idfon has none.

**The problem is to carry MCP over an identity-addressed, peer-to-peer
channel with no public endpoint, and make adding a server as dynamic as adding
a contact, without reimplementing MCP semantics.**

This became tractable exactly because of the `2026-07-28` revision. MCP is now
stateless — every request carries its protocol version and capabilities in
`_meta`, there is no handshake, and servers never initiate JSON-RPC requests.
Each message is self-contained, so a message-shaped, identity-addressed
transport is a natural fit instead of a fight.

## Two distinct roles

| role | direction | what it buys |
|---|---|---|
| **Transport binding** | idfon connects an MCP client to a *remote* MCP server | reach remote servers with no web exposure |
| **MCP server** | idfon exposes *local* idfon capabilities to an agent | the agent can act in idfon; idfon supplies device-capability consent |

They are complementary, not alternatives. Being a transport lets an agent talk
to remote MCP servers. Being a server lets an agent send messages, place
calls, fetch blobs, and (later) capture the screen — through the MCP interface
the agent already speaks.

**Benefits of idfon also being an MCP server:**

- **Actuators.** `idfon.send_message`, `idfon.list_contacts`, `idfon.put_blob`,
  `idfon.start_stream` become MCP tools. Without them an agent can read from
  remote servers but cannot do anything with the user's idfon identity.
- **Consent MCP does not have.** MCP has no model for "this agent may use my
  camera for this session." Mapping tools to grants/leases/kill-switch makes
  idfon the consent boundary for device capabilities.
- **Zero integration.** Any MCP host can connect to a local idfon MCP server
  and get these tools with no custom SDK.
- **Symmetry.** Local idfon capabilities and remote MCP servers both appear to
  the agent as MCP servers — one mental model, no special case.

**Rule:** implement the MCP server as a separate, daemon-backed adapter over
`idfon-client` on the **user side**. `idfond` must not absorb MCP, tool, or LLM
semantics. If the daemon needs to know what a tool is, the abstraction leaked.

## Where each side runs

The two ends of an MCP-over-idfon connection have different local shapes, and
conflating them is the main design trap.

| side | local shape | why |
|---|---|---|
| **agent sandbox** | embedded node (`idfon-core`, own endpoint + key) | one long-lived process, one identity; no multi-client need, and a sandbox may not permit a background service at all |
| **user device** | `idfond` daemon | many clients (GUI + CLI + MCP host), one identity, state persisted across short-lived invocations |

**The rule: a daemon is needed iff multiple local processes must share one
identity.** An agent is a single process, so it embeds the node and owns its
endpoint directly. This needs no new machinery: `idfon-core` has no dependency
on the daemon, and `IrohTransport::bind_with_key(Some(key))` creates a
standalone endpoint. `idfon-client` (the daemon IPC client) is what an agent
must *not* need.

Consequences:

- The agent side opens bi-streams directly from its embedded endpoint. No local
  socket, no IPC stream multiplexing, no daemon.
- A sandbox identity is **ephemeral unless its key is provisioned** (mounted
  secret or env). Because grants are bound to the endpoint id, an ephemeral
  key means re-granting per session. Provision a stable key, or expect
  per-session capability tickets.
- The user side keeps the daemon. The daemon-relay problem (getting a
  bi-stream out of a daemon for a separate local process) only arises *there*,
  whenever a local MCP host must use the daemon-owned endpoint — inbound
  (idfon as MCP server) or outbound (dialing an agent).

## Architecture: bridge, not host integration

```
MCP host ──stdio──▶ idfon-mcp connect ──iroh idfon/mcp/1──▶ idfon-mcp serve ─stdio──▶ MCP server
                    (embedded node,                            (embedded node,
                     agent sandbox)                             server side)
```

Two options were considered:

- **A. Agent host implements the idfon transport.** Maximum integration, but
  every host needs an idfon transport in its SDK.
- **B. A bridge process exposes a local stdio MCP endpoint and tunnels it over
  iroh.** The MCP host sees an ordinary local stdio server; the remote server
  sees an ordinary local client. Every existing MCP client works unchanged.

**B is preferred.** The bridge embeds `idfon-core` and owns the endpoint; it
does **not** talk to a daemon. That is what makes it possible — a
sandbox-friendly single process with no IPC and no background service. The
contact ticket is the entire bootstrap. Optionally, a host that wants native
iroh could embed the transport directly instead of spawning a bridge.

## The wire binding (`idfon/mcp/1`)

### Connection establishment

A peer's contact ticket (endpoint id + address) is the server address. The
client bridge dials the peer with ALPN `idfon/mcp/1` from its **embedded
endpoint** (no daemon); the server bridge accepts on its own embedded endpoint
and routes to its configured local MCP server. The binding is identical
regardless of whether a given deployment packages the node as an embedded
library or a daemon — only the local plumbing differs.

### Framing — stream profile (primary)

Reuse the stdio framing verbatim, as the specification recommends for custom
transports over reliable bidirectional byte streams: UTF-8 JSON-RPC,
newline-delimited, over one reliable bidirectional byte stream. Iroh QUIC
bi-streams provide exactly that.

No envelope metadata mirroring is required in this profile — the body is the
source of truth, so there is no `HeaderMismatch` surface to define.

### Framing — message profile (deferred, idfon-specific)

For store-and-forward queuing when a peer is offline, each JSON-RPC message
becomes an idfon message, correlated by JSON-RPC `id`. This goes beyond
stdio/Streamable HTTP semantics and must be documented as an idfon extension,
not as core MCP behavior. It is not required for the first implementation.

If used, it needs envelope metadata mirroring for routing without body parsing:

| Streamable HTTP header | idfon envelope field | purpose |
|---|---|---|
| `MCP-Protocol-Version` | `mcp.protocolVersion` | version check → `-32022` |
| `Mcp-Method` | `mcp.method` | route/filter without parsing the body |
| `Mcp-Name` | `mcp.name` | tool/resource name |
| `x-mcp-header` | `mcp.headers{}` | tool parameters promoted to metadata |

The body remains authoritative. A mismatch between mirrored metadata and the
body must be rejected with `HeaderMismatch` (`-32020`).

### Cancellation

- **Stream profile:** close the response stream, exactly as Streamable HTTP
  does.
- **Message profile:** a `notifications/cancelled` message (the stdio
  convention), or map onto idfon's `operation.cancel`.

### `subscriptions/listen`

`subscriptions/listen` is a request whose response is a long-lived notification
stream. The stream profile supports it directly by leaving the bi-stream open.
The message profile would need a dedicated stream, so **subscriptions require
the stream profile.**

Opt-in notification types per the spec: `toolsListChanged`,
`promptsListChanged`, `resourcesListChanged`, `resourceSubscriptions`. The
server tags notifications with `io.modelcontextprotocol/subscriptionId`.

### MRTR and tasks pass through unchanged

The binding carries `InputRequiredResult` (`resultType: "input_required"` +
`inputRequests` + `requestState`) and the client's retry with `inputResponses`
without interpretation. The same applies to the official
`io.modelcontextprotocol/tasks` extension. No transport work is required.

## Discovery over idfon

### Live `server/discover`

The client bridge writes one newline-framed request:

```json
{"jsonrpc":"2.0","id":"1","method":"server/discover","params":{"_meta":{
  "io.modelcontextprotocol/protocolVersion":"2026-07-28",
  "io.modelcontextprotocol/clientInfo":{"name":"idfon-bridge","version":"0.1.0"},
  "io.modelcontextprotocol/clientCapabilities":{}}}}
```

The server bridge forwards it to the local MCP server and returns the framed
result:

```json
{"jsonrpc":"2.0","id":"1","result":{"resultType":"complete",
  "supportedVersions":["2026-07-28"],
  "capabilities":{"tools":{},"resources":{},
    "extensions":{"io.modelcontextprotocol/tasks":{}}},
  "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"idfon-peer","version":"0.1.0"}},
  "instructions":"...","ttlMs":3600000,"cacheScope":"private"}}
```

### Ticket-embedded discovery

Normally, adding a remote MCP server means editing configuration and
**restarting the host**. Carrying a cached `DiscoverResult` in the contact
ticket removes both the restart and static configuration: adding an agent is
adding a contact.

```
ticket {
  transport: "idfon",
  peer:      <endpoint id / address>,
  discover?: { supportedVersions, capabilities, serverInfo, instructions, ttlMs, cacheScope }
}
```

Two invariants:

- **It is a cache, not the truth.** `ttlMs`/`cacheScope` exist because
  discovery goes stale. Store it as a hint and refresh with a live
  `server/discover` when the TTL expires or capabilities are needed.
- **`serverInfo` is self-reported and explicitly unverified.** The idfon
  ticket signature proves *transport* identity (the endpoint key); it says
  nothing about the MCP server's claimed name/version. Use it for display
  only, never for a security decision.

## Bridge lifecycle

1. **Local endpoint.** The agent-side bridge exposes stdio (default) to the
   MCP host, presenting itself as an ordinary stdio MCP server. It owns an
   embedded node and never contacts a daemon.
2. **Identity.** The embedded node binds with a provisioned key (stable across
   runs) or a fresh ephemeral key (grants must be re-minted per session).
3. **Peer set.** Each configured peer that is an MCP server has a contact
   ticket. The bridge may prefetch and cache `server/discover` per peer.
4. **Request path.** A client request is framed (newline-delimited JSON-RPC)
   and sent over the idfon stream to the peer bridge.
5. **Server bridge.** Accepts ALPN `idfon/mcp/1` on its own endpoint, spawns
   the configured local MCP server (or connects to it), and splices bytes.
6. **Subscriptions.** A `subscriptions/listen` response stream is held open;
   notifications are relayed to the agent host as they arrive.
7. **Cancellation.** Stream profile closes the request's response stream.
8. **Offline peers.** Deferred: message profile queues requests until the peer
   is reachable. Until then, treat an unreachable peer as a transport error.
9. **Shutdown.** Close all streams and the embedded endpoint.

## What a transport must guarantee (from the spec)

These are the MUSTs the binding inherits and must not violate:

- Deliver client→server requests/notifications and server→client
  responses/notifications. **No other direction exists** — servers never
  initiate JSON-RPC requests; clients never send responses.
- Preserve the JSON-RPC message format, the message patterns, and the
  per-request `_meta` metadata model.
- All protocol metadata travels in the body; envelope mirroring is optional
  and must define mismatch rejection.
- Version mismatches return `UnsupportedProtocolVersionError` (`-32022`).

## Glossary

- **MCP message / frame.** One JSON-RPC object (request, response, or
  notification). *Framing* is only how the transport delimits one message from
  the next — a newline (stdio), an HTTP body (Streamable HTTP), or one idfon
  message.
- **MRTR (Multi Round-Trip Requests).** Introduced in `2026-07-28`. Replaces
  server-initiated requests. A server needing more input returns
  `resultType: "input_required"` with an `inputRequests` map; the client
  retries the original request with `inputResponses`. An opaque `requestState`
  correlates across retries. Keeps the protocol stateless.
- **Tasks.** The `io.modelcontextprotocol/tasks` extension for long-running
  work. The server returns a task handle; the client polls `tasks/get` and can
  push input with `tasks/update`. Maps almost directly onto idfon's async
  `operation.get` / `operation.wait`.

## Open decisions

1. **Resolved: bridge (B).** The agent-side bridge embeds `idfon-core`; no
   daemon. A host that wants native iroh can embed the transport instead.
2. **Resolved: stream profile first.** The message profile is deferred until
   offline peers are a real requirement.
3. **stdio is the agent-side endpoint.** Unix sockets only matter on a
   daemon-backed user side, if one is ever needed there.
4. **Peer→MCP-server mapping** is owned by the bridge process on the server
   side (spawn/connect per configured peer). On the user side it would be the
   daemon's job.
5. **`cacheScope` handling.** A remote peer's `tools/list` over a private
   channel is `"private"`; idfon must respect that when caching in a contact
   record.

## References

- MCP `2026-07-28` changelog, `server/discover`, `basic/transports`,
  `basic/transports/streamable-http`, `basic/patterns/mrtr`,
  `basic/patterns/subscriptions`, `basic/lifecycle`.
- `docs/communication-model.md` — capability/consent model.
- `docs/protocol.md` — idfon daemon IPC.
