# idfon as an Eve Ingress Channel

> **Status:** design; no code. Companion to
> `docs/agent-conversation-plane.md` (the C1 bridge, now superseded by this
> approach for Eve) and `docs/mcp-transport.md` / `docs/mcp-agent-report.md`
> (idfon's tool transport). Written 2026-09-14.

## The idea

Make idfon a **first-class Eve ingress channel** instead of an agent-side
bridge that speaks Eve's session API.

An Eve agent is reachable through *channels* — edge adapters that normalize
input, own the address→session mapping, and decide delivery. Eve ships a base
HTTP channel plus Slack/Discord/… and an MCP channel. An **idfon channel**
would let idfon peers reach the agent, with the **idfon peer identity as the
authenticated principal** rather than a bearer token.

This is the same shape as Slack, with two differences:

- the "platform" is idfon (peer-to-peer, no public endpoint);
- the identity is cryptographic (endpoint id + idfon signatures), not a
  platform account or OAuth token.

## Why a channel, not a bridge to `/eve/v1/session`

The earlier C1 design (`docs/agent-conversation-plane.md`) proposed an
agent-side bridge that owns an `idfon-core` endpoint and calls Eve's HTTP
session API. That works, but it puts conversation semantics
(address→session, delivery, auth) in a bespoke translator. A channel is the
sanctioned place for exactly those responsibilities:

| responsibility | where it belongs | channel gives it |
|---|---|---|
| normalize input into a message | edge adapter | yes |
| map a platform conversation → durable session | channel-local address | yes |
| decide delivery (where/how replies go) | channel | yes |
| authenticate the caller → principal | channel `auth` (`AuthFn` → `sessionAuth`) | yes |
| approvals / elicitations | channel delivery path | yes |
| distribution | Eve extension registry | yes |

Concretely, a channel lets us:

- Make the **idfon peer the principal**: verify the peer's identity and return
  `sessionAuth` (`principalId`, `principalType`, `authenticator`,
  `attributes`). Then `session.auth.current` is a real peer, usable by
  approval policies, per-caller connection lookup, and `forwardPrincipal`.
- Use the channel's **address model** for threading instead of inventing
  `conversation_id` handling in a bridge.
- Ship as an **extension** (`eve add extension/idfon`) contributing a channel.

## The constraint: channels are HTTP/WS route edges

Eve channels declare route handlers (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`,
`WS`) and an `events` map, and drive sessions with `send(address, input)` and
`from(address).send(...)`. **iroh is not a route.**

So a channel alone cannot terminate `idfon/mcp/1` or the idfon message plane.
Something must translate idfon transport → the channel's entry point. That
terminator is the only remaining component; everything above it is an ordinary
Eve channel.

This also means the design is **self-hosted only**: a long-lived iroh endpoint
cannot run in Vercel's serverless/workflow model. (Same conclusion as the
bridge design, for the same reason.)

## Architecture

```
idfon peer ──message/stream (iroh)──▶ idfon terminator ──▶ idfon channel ──▶ Eve session core
   ▲                                        │                    │
   └──────────── idfon message ◀────────────┴──── delivery ◀─────┘
```

- **Terminator** (co-located, self-hosted): owns/borrows the idfon endpoint,
  accepts `idfon/mcp/1` bi-streams and message-plane traffic, verifies peer
  identity, and hands each message to the channel.
- **idfon channel** (authored in the Eve app / shipped as an extension):
  normalizes the message, resolves the address → durable session, routes
  approvals, and delivers replies back through the terminator.
- **Session core**: unchanged. The channel is one ingress among HTTP, Slack,
  MCP, ACP.

## Address → session

The channel-local address is what maps a conversation to a durable session:

- **address** = idfon peer endpoint id, optionally scoped by a
  `conversation_id` for multiple threads per peer.
- One peer (or peer+thread) ↔ one Eve `sessionId`, persisted by the channel so
  follow-ups resume the same durable conversation.
- `turnPolicy` (Eve's `steer`/`queue`) decides what happens when a message
  arrives mid-turn; idfon message delivery order is preserved either way.

This replaces the bridge's ad-hoc threading with the same mechanism Slack and
the HTTP channel use.

## Auth: peer identity as principal

Eve's channel `auth` is an `AuthFn` that returns a principal (or `null`).
The idfon channel verifies the idfon peer cryptographically and maps it:

| idfon | Eve principal |
|---|---|
| endpoint id (verified) | `principalId` |
| "idfon peer" | `principalType` (custom or mapped) |
| idfon signature / PeerAuth | `authenticator` |
| capability grants, aliases | `attributes` (e.g. `endpoint_id`, grants) |

Consequences:

- **No bearer to distribute.** The caller authenticates by holding the peer's
  key; there is no token to embed, leak, or rotate.
- **Grants as the edge gate.** The same hook can require `message.send` (or
  `mcp.transport`) for the peer before accepting a turn. idfon grants become
  the ingress authorization, and map naturally onto Eve's approval policies.
- **Revocation is unilateral.** Revoking the idfon grant cuts the peer off
  without cooperation from the agent side.
- **`forwardPrincipal`** can carry the peer identity to subagents and
  `defineRemoteAgent` calls, so delegation preserves the caller.

Where an Eve app also has its own app/user identity (OIDC, connections), the
peer principal augments it rather than replacing it; the mapping of "which Eve
principal does a peer become" is app policy (see open questions).

## Delivery and content

- **Text**: idfon `message.send` → a turn; reply events
  (`message.completed`, `action.result`) → outbound idfon messages.
- **Artifacts**: an idfon **blob ticket** maps to a channel file part
  (`UserContent` / `fetchFile`); the agent's own outputs go back as blob
  tickets rather than external URLs or sandbox paths (Eve explicitly does not
  treat sandbox files as durable storage).
- **Live media**: an idfon **stream ticket** has no Eve session equivalent; it
  is delivered through idfon's media plane and referenced in the turn.
- **Typing/status**: optional, from `turn.started` / `actions.requested`.

## Human-in-the-loop

Eve approvals and elicitations already park the turn durably and emit
`input.requested` / `authorization.required`. The channel maps those to an
idfon request→response pair (a message carrying the request id/options, then
the peer's response), and answers with `inputResponses` on the follow-up.
`inputResponses` never steer, matching Eve's contract. This is the concrete
mechanism for "computer-use needs consent": the approval rides the same path
as any other idfon message, and the consent decision can also consult the
peer's idfon grants.

## Terminator options

The channel is the semantics; the terminator is packaging. Two shapes:

1. **Loopback terminator (recommended).** A co-located process terminates the
   idfon transport and POSTs each verified message to the idfon channel's
   route on localhost (with the peer identity attached in a trusted header or
   signed envelope). The channel then calls `send(...)` normally.
   - Pro: the channel stays an ordinary HTTP/WS channel — no unsanctioned
     listener, works with Eve's route/auth machinery and extension packaging.
   - Con: one more process to run; a loopback hop; identity must be attested
     to the channel (the channel must not trust a client-supplied header).
2. **In-process listener.** The Eve Node service opens the iroh endpoint itself
   (a JS/native iroh binding or a child process) and calls `send(...)`
   directly.
   - Pro: no extra hop, identity is in-process.
   - Con: not the documented channel contract; lifecycle (dev watch,
     generations, restarts) is on us; requires credible Node iroh bindings.
     Self-hosted only either way.

The existing Rust `crates/idfon-mcp` can be the seed of the terminator: it
already owns an endpoint, registers `idfon/mcp/1`, and pumps streams. The
change is to forward to the channel route instead of a spawned stdio command.

## What is new vs reused

- **Reused (already implemented):** idfon transport and ALPN, the daemon relay
  for the user side, contact tickets, grants, blob/stream tickets.
- **New:** an idfon Eve channel (auth/principal mapping, address→session,
  delivery, HITL mapping) and the terminator that feeds it. Ships as an Eve
  extension plus a small binary.

The user side is unchanged: idfon clients still message the peer through
`idfond`; they never learn an Eve path.

## Relationship to the MCP tool axis

Two orthogonal edges, both standard:

- **Conversation** → idfon channel (this document).
- **Tools** → MCP: Eve consumes idfon capabilities via
  `defineMcpClientConnection` (Streamable HTTP facade over `idfon-mcp-server`),
  and idfon reaches the Eve agent's MCP channel over `idfon/mcp/1` (teach
  `idfon-mcp serve` a Streamable HTTP upstream).

Do not collapse them: an idfon channel is an ingress for turns, not a tool
surface; MCP remains the tool surface.

## Why not Chat SDK / Vercel Connect

Neither replaces a custom `defineChannel`; each avoids only part of the work.

**Vercel Chat SDK** (`chatSdkChannel`) is a shortcut *if* the hard parts are
already solved. Implementing a Chat SDK adapter would let the app use
`chatSdkChannel` (`bot`/`channel`/`send`, threads, durable state, cards)
instead of a raw `defineChannel`. But:

- Adapters are **webhook/HTTP-oriented** — provider auth, webhook
  verification, delivery mounted at `/eve/v1/{adapter}` — so they do **not**
  terminate iroh; the terminator still exists.
- Chat SDK has **no cryptographic peer principal**. Its identity model is the
  platform account; `sessionAuth` from a verified idfon peer signature — the
  main reason to build the channel — is still ours to implement.

Worth it only if you also want its message/card/thread primitives; otherwise a
`defineChannel` is smaller, hands you the `auth` hook directly, and avoids a
Vercel messaging dependency in a self-hosted P2P design.

**Vercel Connect** is orthogonal and largely counter to the goal. It brokers
*outbound* credentials/OAuth (short-lived tokens to third-party APIs) and
registers *inbound* platform webhook triggers (Slack). idfon's edge replaces
bearer/OAuth with peer identity, and Connect is Vercel-managed infrastructure —
neither gives a transport nor a peer-identity principal, so it does not help
make idfon a channel. It could still broker credentials for the agent's
outbound third-party calls, which is unrelated to this ingress.

## Deployment

Self-hosted only, for both the terminator and the agent runtime. Vercel-hosted
Eve cannot hold the idfon endpoint and already exposes its own public
authenticated HTTP surface, so idfon adds identity/consent there but not the
no-public-endpoint property.

## Open questions

- **Principal mapping.** What `principalType`/`principalId` shape should a peer
  become, and how does it compose with an app's existing OIDC/user principals
  and per-caller connection lookup?
- **Multi-thread per peer.** Is `conversation_id` a first-class address token,
  or one peer = one session by default?
- **Terminator trust.** How is the peer identity attested to the channel in the
  loopback shape (signed envelope vs mTLS vs a per-install secret)?
- **Streaming.** Do agent token deltas ride idfon (progress/stream channel) or
  are replies coalesced per turn?
- **Extension packaging.** Can the channel + terminator ship as one Eve
  extension, or does the terminator have to be a separately deployed sidecar?
- **ACP overlap.** Is the idfon channel distinct from, or layered on, Eve's ACP
  support (stdio, local)?

## References

- `docs/agent-conversation-plane.md` — the conversation plane; the C1 bridge
  this supersedes for Eve.
- `docs/mcp-transport.md` — `idfon/mcp/1`.
- `docs/mcp-agent-report.md`, `docs/mcp-implementation-plan.md` — tools,
  grants, roadmap.
- Eve channels: `https://eve.dev/docs/channels/overview` (channel contract,
  `defineChannel`, custom channels); `.../channels/eve` (base HTTP channel);
  `.../human-in-the-loop` (approvals/elicitations); `.../extensions`.
