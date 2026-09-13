# AI Agents in Idfon — Design Report

> **Status:** design findings, no code. Written 2026-09-13 during prototyping.
> Companion to `docs/mcp-transport.md` (the concrete binding).
> Idofn is in prototyping; legacy/migration compatibility is explicitly not a
> constraint.

## Summary

Idofn can host AI agents as contacts with almost no new machinery, because its
model is already "an opaque endpoint plus subject-bound capabilities." An agent
is a peer with a compute loop behind it. The valuable properties fall out of
the existing transport rather than being bolted on:

- The agent's control plane is a **peer relationship, not a public HTTP
  endpoint** — no inbound port, no API key on the internet, no cert, no reverse
  proxy.
- Reachability is iroh's problem (hole-punch + relay).
- Authorization is idfon's grant model, which is subject-bound and revocable
  without the peer's cooperation.

The integration surface is **MCP**, which is what makes this cheap: one
implementation covers every MCP-capable agent framework instead of a binding
per framework.

The two ends are shaped differently and that is intentional: the **user
device** keeps the `idfond` daemon (many clients, one identity), while the
**agent sandbox embeds the node** as a library (one process, one identity, and
possibly no permission to run a background service). See "Deployment shape"
below.

## Corrected facts: MCP `2026-07-28`

Earlier assumptions in this design thread were based on MCP `2025-06-18` and
are wrong. The current revision (previous: `2025-11-25`) changed:

- **Stateless.** `initialize`/`notifications/initialized` are gone. Every
  request carries `io.modelcontextprotocol/protocolVersion`,
  `clientInfo`, and `clientCapabilities` in `_meta`; servers identify in
  results via `serverInfo`. No session, no handshake.
- **`server/discover` is mandatory.** Servers advertise supported protocol
  versions, capabilities, and identity in one request. This is what the
  "idfon should send the agent its MCP configuration metadata" idea actually
  is; MCP already owns that surface.
- **No server-initiated requests.** Replaced by **MRTR**: a server returns
  `resultType: "input_required"` with `inputRequests`; the client retries the
  original request with `inputResponses` and an opaque `requestState`.
- **All results carry `resultType`** (`"complete"` | `"input_required"`).
- **`subscriptions/listen`** replaces the HTTP GET stream and
  `resources/subscribe`/`unsubscribe`: one long-lived response stream for
  opted-in change notifications, tagged with `subscriptionId`.
- **Tasks moved to an extension** (`io.modelcontextprotocol/tasks`): poll
  `tasks/get`, push input with `tasks/update`.
- **Transports are explicitly pluggable**, and custom transports over a
  reliable byte stream **should reuse the stdio framing**.
- **Deprecated:** Roots, Sampling, Logging; HTTP+SSE; OAuth Dynamic Client
  Registration.
- **Authorization** for HTTP transports is OAuth 2.1; identity in
  `server/discover` is self-reported and explicitly unverified.
- Error codes: `HeaderMismatch -32020`, `MissingRequiredClientCapability
  -32021`, `UnsupportedProtocolVersion -32022`.
- Caching: `ttlMs` / `cacheScope` on list and read results; `tools/list`
  should be deterministically ordered.

**Consequence:** the old framing — "MCP leaves discovery/identity/auth
unspecified, so idfon supplies them" — is obsolete. Idofn's role is narrower
and cleaner: **an MCP transport binding plus peer rendezvous**, adding what
MCP genuinely lacks (P2P reachability, no web exposure, cryptographic peer
identity, device-capability consent).

## What idfon uniquely supplies

- **Peer discovery over P2P.** Every MCP transport assumes the client already
  knows a command or URL. Idofn's ticket model is exactly that bootstrap.
- **No web exposure.** Remote MCP means a public Streamable HTTP endpoint;
  idfon means none exists.
- **Verifiable peer identity.** `serverInfo` is informational; idfon's
  `PeerAuth` signatures are cryptographic.
- **Device-capability consent.** OAuth models "user authorizes a server."
  Idofn's grants/leases model "this agent may use my camera for this session,"
  which is the computer-use case and is not something OAuth covers.

## Design conclusions

### Agents are peers

An agent is an iroh endpoint with its own keypair, added to the peer list like
a contact. Its own identity is a **security requirement**, not a nicety: an
agent running under the user's identity inherits every grant and contact.

### Deployment shape: daemon on the user side, embedded on the agent side

The two ends have different local shapes, and conflating them is the main
design trap.

| side | local shape | why |
|---|---|---|
| user device | `idfond` daemon | many clients (GUI + CLI + MCP host), one identity, state persisted across short-lived invocations |
| agent sandbox | embedded node (`idfon-core`, own endpoint + key) | one long-lived process, one identity; no multi-client need, and a sandbox may not permit a background service |

**A daemon is needed iff multiple local processes must share one identity.**
An agent is a single process, so it embeds the node and owns its endpoint.
This needs no new machinery: `idfon-core` has no dependency on the daemon,
and `IrohTransport::bind_with_key(Some(key))` creates a standalone endpoint.
`idfon-client` (the daemon IPC client) is what an agent must *not* need. The
daemon-relay and IPC-multiplexing problems only exist on the user side.

Consequence: a sandbox identity is **ephemeral unless its key is provisioned**,
and grants are bound to the endpoint id — so either provision a stable agent
key (mounted secret / env) or re-mint capability tickets per session.

### Three planes

- **Conversation** — turns, streaming, modality. Idofn messages, optionally
  ACP-shaped. ACP is a vocabulary donor, not a required base; framework
  integration matters more than ACP conformance, so ACP is one adapter.
- **Tools / doing** — MCP. Every framework that speaks MCP works.
- **Identity / transport / authorization** — idfon.

Recorded/discrete media (a voice memo, a photo, a screenshot) are content
blocks or blob tickets. Live media (voice/video/streams) rides idfon's
existing media plane and is referenced by a descriptor correlated to the
session.

### Voice: negotiated per direction, transcript-first

STT/TTS location is negotiated and mutable within a session because
availability varies (on-device models present or not, network quality, agent
capability):

```
voice: { input: client|agent|either, output: client|agent|either,
         recordTranscript: client|agent, live: bool }
```

- Client-side voice: any text agent works, best privacy.
- Agent-side voice: voice-specialized agents, thin client.
- Mixed: legitimate and probably common.

**Interaction-path transcription and archival transcription are separate.**
The control plane always carries transcript updates regardless of who does
voice; audio is presentation. If an agent emits no transcript, the client can
run local STT on the returned audio purely for the record. This also gives
clean degradation: lose audio, flip to text in the same session.

### Tools are open, not enumerated

`Capability` is currently a closed serde enum, which makes every new tool a
core protocol change. Proposed: **namespaced string capability names**
(`core.message.send`, `screen.capture`, `browser.click`), with **opaque args**
to idfon and **provider-declared schemas**. The daemon authorizes on the name
and nothing else. Then adding a tool is registering a provider, not shipping a
protocol revision.

Invocation returns one shared result vocabulary: `text | render | blob ticket |
stream ticket | error`. Tool results and agent output use the same shapes.

### Computer-use is a namespace, not a subsystem

Computer-use and browser-use are invocations like any other: the agent requests
a capability, the client grants under a lease, and the result is a blob or a
stream.

- **Discrete capture → blob ticket** (a screenshot is `media.resource.put`).
- **Sequence/video → stream ticket** with a finite end (`endsAfter`).
- Computer-use agents are turn-based and rarely need dense video; blob-first is
  both lazier and better.
- The capture operation spec (target, region, count, mode, selection) is the
  **provider's schema**, not idfon's protocol. It is also the consent
  disclosure: "5 frames of the top-right 400×300 for 30s" is evaluable;
  "screen access" is not.

### idfon as an MCP server

Being a transport binding reaches remote MCP servers. Also being an MCP server
lets an agent use the user's idfon identity and device capabilities as tools,
with idfon supplying the consent model MCP lacks. This role lives on the
**user side**, where the daemon exists: implement it as a separate adapter over
`idfon-client`; never inside `idfond`. The agent side has no daemon and does
not need this role.

### Ticket-embedded discovery

A contact ticket can carry the transport binding plus a cached
`DiscoverResult`, making adding an agent a contact-add rather than a config
edit and restart. It is a cache hint (respect `ttlMs`/`cacheScope`) and its
`serverInfo` is unverified.

## Decisions

| # | decision | status |
|---|---|---|
| D1 | idfon is an MCP transport binding; MCP is the tool interface | agreed |
| D2 | bridge architecture; agent side embeds the node (no daemon), bridge exposes local stdio and tunnels over iroh | agreed |
| D3 | stream profile first using stdio framing; message profile deferred | proposed |
| D4 | ticket-embedded `server/discover` as an unverified cache hint | agreed |
| D5 | open namespaced capability names instead of the closed enum | proposed |
| D6 | one shared invocation result vocabulary | proposed |
| D7 | computer-use / browser-use are tool namespaces, not core subsystems | agreed |
| D8 | ACP only where it helps conversation; framework integration via MCP takes priority | agreed |
| D9 | voice location negotiated and mutable; transcript-first | agreed |
| D10 | agent identity separate from user identity | agreed |

## Risks

- **Prompt injection is the load-bearing risk.** Peer messages are untrusted
  input that may read like instructions. Route only the agent's own
  conversation into its context; never the whole inbox or contact graph.
- **Separate identity.** An agent under the user's key inherits everything.
- **Standing grants.** A forgotten leased screen grant is the failure mode.
  Default to per-session leases, visible active indicator, auto-expiry,
  unilateral revoke, global kill switch.
- **Screen capture leakage.** Exclude idfon's own windows; captures reveal the
  contact list and messages (cross-peer leakage).
- **Bearer stream tickets.** Today's live tickets are bearer; screen content is
  the most sensitive data in the system. Prefer subject-bound, short-TTL,
  single-consumer stream tickets before shipping capture.
- **Ephemeral identity vs subject-bound grants.** Re-keying an agent kills
  every grant, and a sandbox gets a fresh key unless one is provisioned. Either
  provision a stable agent key (mounted secret / env) or re-mint capability
  tickets per session. A stable logical agent id is a later problem.
- **Coupling.** LLM/MCP/tool semantics must not enter `idfond`. The daemon is a
  transport and identity store.
- **Agent meshes amplify.** Add rate/loop guards before agent-to-agent.

## Open questions

- Whether MRTR/tasks map onto idfon operations or ride opaque MCP messages.
- Whether a sandbox key is provisioned (stable identity) or capability tickets
  are re-minted per session.
- What replaces `Mcp-Method`/`Mcp-Name` in idfon envelopes if the message
  profile is used.
- `on-change` vs `periodic` capture selection.
- Whether conversation uses ACP shapes or a smaller idfon-native session.

## Roadmap

1. **Zero-code validation.** Script an agent adapter over `idfon events
   --follow` + `idfon send`; confirm a model-backed peer over iroh is pleasant.
2. **Transport binding.** Agent-side bridge embedding `idfon-core` (no daemon)
   + stream profile + `server/discover` + `subscriptions/listen`;
   ticket-embedded discovery for dynamic contact-add.
3. **idfon as MCP server.** Daemon-backed adapter over `idfon-client`:
   capabilities as tools, grants as consent.
4. **Tool platform.** Open capability names, invocation result vocabulary,
   provider registration.
5. **Device capabilities.** Capture provider, leases, subject-bound stream
   tickets — screen/camera as a tool namespace.
6. **Voice/media.** Modality negotiation, transcript-first, media binding.
7. **Agent-to-agent.** Only after loop/rate guards.

## Explicitly out of scope (do not build yet)

- A global agent/tool directory — it would recreate the registry idfon avoids.
- An LLM or MCP runtime inside `idfond`.
- A bespoke agent RPC protocol where MCP suffices.
- Token-streaming chat if whole messages work.
- Act-as-user delegation.
- Full ACP conformance.
