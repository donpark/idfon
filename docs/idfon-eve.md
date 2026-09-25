# idfon as an Eve Ingress Channel

> **Status:** implemented through M0–M5; the iOS text-demo follow-up is tracked in [#11](https://github.com/donpark/idfon/issues/11). Companion to `docs/agent-conversation-plane.md`
> (the framework-agnostic C1 bridge, superseded for Eve by this approach) and
> `docs/mcp-transport.md` / `docs/mcp-agent-report.md` (idfon's tool transport).
> Implementation history and acceptance coverage are tracked in
`docs/idfon-eve-implementation-plan.md`.
> Written 2026-09-14; revised 2026-09-14 (provider-owns-endpoint framing,
> replies-over-iroh, Slack mapping, no-public-endpoint property).

## The idea

Make idfon a **first-class Eve ingress channel**, i.e. an idfon channel
*provider* that any Eve agent can install, exactly as it installs
`channel/slack` or `channel/discord`.

An Eve agent is reachable through *channels* — edge adapters that normalize
input, own the address→session mapping, and decide delivery. Eve ships a base
HTTP channel plus Slack/Discord/…, an MCP channel, and custom channels
(`defineChannel`). An **idfon channel** lets idfon peers reach the agent with
the **idfon peer identity as the authenticated principal** rather than a bearer
token, and with **no public endpoint**.

This is the same shape as Slack. The difference is where the "platform" lives:

| | Slack channel | idfon channel |
|---|---|---|
| platform | remote, always-on Slack servers | the idfon peer network; **the provider holds the endpoint itself** |
| inbound | Slack pushes a webhook to a public route | the provider accepts inbound iroh connections on its own endpoint |
| outbound | channel calls the Slack Web API | channel calls `message.send` over iroh |
| identity | platform account / OAuth bearer | cryptographic endpoint key + idfon grants |
| reachability | public HTTPS URL required | none — endpoint id + discovery + relay |

Slack's platform is a remote broker that holds the event stream for you. idfon
has no broker, so **the channel provider is also the platform endpoint**: it
binds an iroh endpoint and listens. That single fact is what removes the public
website (and what makes the "terminator" question simple — see below).

## The provider owns the endpoint

A channel is the edge adapter; for idfon the edge is an iroh endpoint, so the
provider must hold one. Concretely the idfon channel provider ships as:

1. an **endpoint holder** that owns the agent's iroh key and endpoint, accepts
   inbound connections on `idfon/message/1`, verifies peer signatures and
   tickets, and sends replies; and
2. an **Eve channel** authored with `defineChannel` that does the
   channel-contract work (normalize input, own address→session, auth, events,
   delivery).

These are two roles; whether they are two processes is **packaging, not
semantics** (see "Packaging" below). Both are part of the provider.

### "Listening" and "termination", precisely

To *terminate* a connection means to be the endpoint that ends it — accept the
transport and hand the payload onward (as a TLS terminator does). An **iroh
terminator** is just the provider's accept side. It is **not** one-way and it
does **not** separate requests from responses: QUIC is bidirectional, and
idfon already uses that — `message.send` returns an ack and "auto-establishes
the local receive side of the reply path" (`docs/protocol.md`).

So the earlier framing of a separate "terminator component" plus a distinct
"delivery" hop was a packaging artifact, not a protocol requirement:

- **endpoint in the Eve process / a managed child:** the channel's event
  handlers call `message.send` directly. One process boundary at most; no
  third component.
- **endpoint in an external process:** the reply crosses back to that process
  to reach the wire. That is the only reason a "delivery hop" appears.

A reply is never blocked by the endpoint being on the accept side. An Eve
response goes back over the idfon channel in both shapes.

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
  `attributes`). `session.auth.current` then holds a real peer, usable by
  approval policies, per-caller connection lookup, and `forwardPrincipal`.
- Use the channel's **address model** for threading instead of inventing
  `conversation_id` handling in a bridge.
- Ship as an **extension** (`eve add channel/idfon`) contributing a channel.

## Architecture

```text
idfon peer ──message/stream (iroh)──▶ endpoint holder ──▶ idfon channel ──▶ Eve session core
   ▲                                        │                   │
   └──────────── idfon message ◀────────────┴──── delivery ◀────┘
```

- **Endpoint holder** (part of the provider): owns/borrows the agent's idfon
  endpoint key, accepts `idfon/message/1` (and side-channel ALPNs), verifies
  peer identity + capability tickets, and forwards normalized turns.
- **idfon channel** (authored in the Eve app / shipped as an extension):
  normalizes the turn, resolves the address → durable session, routes
  approvals, and delivers replies back through the holder.
- **Session core**: unchanged. The channel is one ingress among HTTP, Slack,
  MCP, ACP.

The user side is unchanged: idfon clients still reach the agent through
`idfond`; they never learn an Eve path or that an Eve is behind the endpoint.

## What the peer is (users and agents are symmetric)

idfon has one principal model: a peer endpoint key. A human idfon client and
another agent runtime are indistinguishable at the channel — both send
`message.send`, both verify to a principal, both start/continue a turn.
Therefore:

- An Eve agent with the idfon channel provider **is an idfon contact**.
- Another idfon-capable peer — a user, or **another agent** — can prompt and
  control it exactly as a user prompts a Slack bot.
- Agent-to-agent is the same edge, not a new one; it needs its own guards
  (per-peer isolation, loop/rate limits) before it is enabled.

This symmetry is stronger than Slack's (which distinguishes workspace, bot,
and user accounts) and follows entirely from idfon's uniform peer identity.

## Address → session

The channel-local address maps a conversation to a durable session:

- **address** = peer endpoint id (or `peer_id`), optionally scoped by a
  `conversation` token for multiple threads per peer.
- One peer (or peer+conversation) ↔ one Eve `sessionId`, persisted by the
  channel so follow-ups resume the same durable conversation.
- `turnPolicy` (Eve's `steer`/`queue`) decides what happens when a message
  arrives mid-turn; idfon preserves message order either way. `queue` is the
  natural default for a remote peer (each turn finishes before the next
  message starts); `steer` matches Eve's channel default.

**The wire already carries the key.** `MessageEnvelope` (in
`crates/idfon-protocol/src/lib.rs`) has a signed `conversation: Option<String>`
field, so per-peer threading needs **no protocol change**. This replaces the
bridge's ad-hoc threading with the same mechanism Slack's `threadTs` and the
HTTP channel's continuation token use.

## Auth: peer identity as principal

Eve's channel `auth` is an `AuthFn` that returns a principal (or `null`). In
Eve `0.55`, the channel's `audience({ auth })` hook also classifies an
authenticated idfon session as private; missing authentication fails closed to
unknown. The idfon channel maps a verified peer:

| idfon | Eve principal |
|---|---|
| endpoint id / `peer_id` (verified) | `principalId` |
| "idfon peer" | `principalType` (custom or mapped) |
| idfon signature / capability ticket | `authenticator` |
| capability grants, aliases | `attributes` (e.g. `endpoint_id`, grants) |

Consequences:

- **No bearer to distribute.** The caller authenticates by holding the peer's
  key; there is no token to embed, leak, or rotate.
- **Grants as the edge gate.** The same hook can require `message.send` (or
  `mcp.transport`) for the peer before accepting a turn. idfon grants become
  the ingress authorization and map naturally onto Eve's approval policies.
  Ordinary turns require `message.receive`; signed A2A envelopes additionally
  require the explicit `agent.receive` grant, keeping agent-vs-human policy at
  the capability boundary.
- **Revocation is unilateral.** Revoking the idfon grant cuts the peer off
  without cooperation from the agent side.
- **`forwardPrincipal`** can carry the peer identity to subagents and
  `defineRemoteAgent` calls, so delegation preserves the caller.

Where an Eve app also has its own app/user identity (OIDC, connections), the
peer principal augments it rather than replacing it; mapping "which Eve
principal a peer becomes" is app policy (see open questions).

**Trust boundary.** The endpoint holder verifies the signature/ticket *before*
the channel sees the turn. The channel must not trust a client-supplied
identity header; in the split-process packaging the holder attests the peer
identity to the channel (signed envelope or a per-install secret), and in the
managed-child packaging the attestation is the IPC channel itself.

## Delivery and content

- **Text**: idfon `message.send` → a turn; reply events (`message.completed`,
  `action.result`) → outbound idfon messages via `message.send`.
- **Artifacts**: an idfon **blob ticket** maps to a channel file part
  (`UserContent` / `fetchFile`); the agent's outputs go back as blob tickets
  rather than external URLs or sandbox paths (Eve explicitly does not treat
  sandbox files as durable storage).
- **Live media**: `idfon__publish-live` (requiring the authenticated
  `live.audio.publish` or `live.video.publish` grant) returns an idfon **stream
  ticket**; file-backed audio and fragmented-MP4 video are delivered through
  the pinned `idfon-media`/MoQ plane and referenced in the turn. It has no Eve
  session equivalent.
- **Typing/status**: optional, from `turn.started` / `actions.requested`.

### Media is where idfon exceeds Slack

Eve's Slack channel **drops `audio` and `video` attachments** (`attachments.ts`
returns `null` for those types); it carries text + images/files. Twilio is
speech-transcribed at the provider edge. idfon can carry, as turn input or
output:

- **durable files** via `iroh-blobs` and `BlobTicket` (content-addressed,
  resumable, verified by hash);
- **completed recordings** (Opus) via blob tickets;
- **live audio/video** via `iroh-live`/MoQ **stream tickets** — real-time,
  multi-rendition, referenced by the turn but not streamed through Eve's
  session model as token events. The Eve holder supports file-backed WAV/MP3/
  FLAC audio and fragmented-MP4 H.264 video.

The protocol already reserves media shape: `MessageContent` currently has only
`Text`, but `MediaResource` / `MediaKind { File, Recording, LiveAudio,
LiveVideo }` and `blob_ticket` exist. A media milestone either extends
`MessageContent` or continues the daemon's existing out-of-band approach (a
text `IDFON-DATA/1` envelope, or a referenced ticket), whichever is smaller.

## Human-in-the-loop

Eve approvals and elicitations already park the turn durably and emit
`input.requested` / `authorization.required`. The channel maps input requests
to an authenticated `IDFON-HITL/1` request and answers them with
`IDFON-HITL-RESPONSE/1` through `inputResponses`; `inputResponses` never steer,
matching Eve's contract. Authorization challenges and lifecycle outcomes use
an authenticated `IDFON-STATUS/1` envelope, including the callback challenge,
`authorization.completed`, `turn.cancelled`, and `turn.failed`.

The holder also forwards validated capability grants into Eve session auth
attributes. Approval policies can therefore require an idfon grant such as
`consent.approve` before asking for human approval. An idfon peer receives an
OAuth challenge/status, but completion still happens through Eve's provider
callback rather than by treating a peer message as a credential callback.

## No public endpoint — and what that does and does not buy

The headline property: **an Eve agent with the idfon channel provider needs no
public website, DNS name, TLS certificate, or inbound port.** Its address is
the endpoint id / ticket; clients dial it.

Honest caveats:

- **Default iroh still uses n0 infrastructure** — public relay + pkarr/DNS
  discovery (`presets::N0`). That is reachability plumbing, not a public
  website, but it is not zero external dependency. Relay and discovery can be
  self-hosted if that matters.
- **Self-hosted, long-lived process.** `eve start` / Node, not a serverless
  function: the endpoint must stay open. (`eve dev` hot-reload also needs the
  endpoint to rebind cleanly — see the plan.)
- **Disable or loopback-bind Eve's default HTTP channel** (`channels/eve.ts`)
  so it does not reintroduce a public route.
- **Reachability ≠ authorization.** Grants and capability tickets still gate
  who may send or invoke; idfon separates connection from permission by design.
  The holder also applies a per-peer rate limit, bounded target/seen-message
  sets, an eight-publisher live quota, and a configurable live-publisher TTL.
  Ticket grants are exposed to Eve approval policies as authenticated session
  attributes, not trusted from the incoming HTTP body.
- **Two orthogonal axes, possibly one endpoint.** Conversation is this channel
  (`idfon/message/1`); service/tool invocation is MCP (`idfon/mcp/1`) or Eve
  Tools. Both avoid public ingress and can share a single endpoint via
  multiple ALPNs, but they are distinct: an idfon channel is an ingress for
  turns, not a tool surface.

## Packaging

The channel contract does not force a separate process; only the endpoint's
lifetime does. Three shapes, in order of preference:

1. **Managed child (future hook).** The desired shape is for the Eve
   extension to spawn the endpoint holder (a Rust binary bundling `idfon-core`)
   and speak a small local IPC protocol to it. Eve 0.55.0 has no custom-channel
   startup hook, so the managed runner below is the current lifecycle coupling.
   Requires future Eve extension support for a bundled binary
   (`eve.extension.externalDependencies` covers native assets/SDKs).
2. **Managed sidecar runner.** `integrations/eve-idfon/managed.mjs`
   owns the Rust holder and bridge as child processes, uses a stable socket/key,
   removes stale locks, forwards termination, and cleans up live publishers.
   Example:
   ```sh
   node integrations/eve-idfon/managed.mjs \
     --holder-command ./eve-idfon \
     --key-file ~/.config/idfon/eve.key --socket /run/user/$UID/idfon-eve.sock \
     --blob-dir ~/.local/share/idfon/eve-blobs \
     --target http://127.0.0.1:52776 --secret "$IDFON_BRIDGE_SECRET" --port 18766
   ```
   Eve 0.55.0 does not expose a custom-channel startup hook, so this is the
   explicit deployment entrypoint rather than an in-extension spawn.
3. **External sidecar.** An operator runs the holder; the channel connects to
   its loopback endpoint. Simplest to develop and debug; one more thing to
   deploy.
3. **Native addon (later, optional).** Drop the Rust binary by exposing
   `idfon-core` through a Node N-API addon. True in-process single process.
   Deferred: no Node iroh binding exists today (`native/vendor/iroh-c-ffi` is
   a C API oriented at the daemon/client), and building one is speculative
   until the semantics are proven.

In all three, the channel contract is the same: routes/events/operations are
documented `defineChannel` surfaces, and the endpoint is the provider's
"platform client". The in-process shape is therefore **not** a contract
violation — the real cost is lifecycle, not legitimacy.

### npm distribution

The provider publishes as the unscoped **`eve-idfon`** package (the
`@idfon` org is not registered), and its version tracks the Cargo workspace
until 1.0. The extension itself is plain TypeScript built by
`eve extension build` in `prepare` (run explicitly from the repo root as
`pnpm eve build` / `pnpm eve clean`, which also builds or cleans the agents);
the Rust holder ships separately as
per-platform packages `eve-idfon-{darwin,linux}-{arm64,x64}` listed as
`optionalDependencies`, mirroring `cli/idfon`. `managed.mjs` (the package's
`bin`) resolves the holder from the installed platform package, with
`integrations/<pkg>` as a repo-layout fallback; `--holder-command` and
`EVE_IDFON_HOLDER` override it. `scripts/build-eve.sh [TARGET]`
populates a platform package (its `bin/` and generated `LICENSE-*` are
gitignored, as with `cli/idfon-*`). No Windows package: the holder IPC is a
Unix socket. Still open: the CI build/publish workflow, a publish script, and
a version-sync guard across the Cargo workspace, `cli/idfon`, and this package.

## The endpoint holder reuses the MCP bridge pattern

`crates/idfon-mcp` is the seed. It already owns an endpoint with
`idfon-core`, registers an ALPN (`add_side_channel`), pumps streams, and never
links `idfon-client` (the agent has no daemon). The differences for the
conversation channel:

| | `idfon-mcp` (tools) | `eve-idfon` (conversation) |
|---|---|---|
| ALPN | `idfon/mcp/1` | `idfon/message/1` (message plane) |
| semantics | pure byte pump | parse/verify `MessageEnvelope`, normalize |
| direction | one bi-stream per MCP connection | discrete messages + reply `message.send` |
| auth | stream is the boundary | per-message signature + capability ticket |
| output | spliced to a child MCP server | forwarded to the Eve channel |

`idfon-core` already exposes everything the holder needs without a daemon:
`IrohTransport::bind_with_key`, `serve(handler)`, `send`, `verify_message`,
`verify_capability_ticket`, and `open_bi_stream(target, alpn)` for side
channels (live media).

## Relationship to the MCP tool axis

Two orthogonal edges, both standard:

- **Conversation** → idfon channel (this document).
- **Tools** → MCP: Eve consumes idfon capabilities via
  `defineMcpClientConnection` (Streamable HTTP facade over `idfon-mcp-server`),
  and idfon reaches the Eve agent's MCP channel over `idfon/mcp/1`.

Do not collapse them: an idfon channel is an ingress for turns, not a tool
surface; MCP remains the tool surface. They may share one endpoint.

## Why not Chat SDK / Vercel Connect

Neither replaces a custom `defineChannel`; each avoids only part of the work.

**Vercel Chat SDK** (`chatSdkChannel`) is a shortcut *if* the hard parts are
already solved. Implementing a Chat SDK adapter would let the app use
`chatSdkChannel` (`bot`/`channel`/`send`, threads, durable state, cards)
instead of a raw `defineChannel`. But:

- Adapters are **webhook/HTTP-oriented** — provider auth, webhook verification,
  delivery mounted at `/eve/v1/{adapter}` — so they do **not** terminate iroh;
  the endpoint holder still exists.
- Chat SDK has **no cryptographic peer principal**. Its identity model is the
  platform account; `sessionAuth` from a verified idfon peer signature — the
  main reason to build the channel — is still ours to implement.

Worth it only if you also want its message/card/thread primitives; otherwise a
`defineChannel` is smaller, hands you the `auth` hook directly, and avoids a
Vercel messaging dependency in a self-hosted P2P design.

**Vercel Connect** is orthogonal and largely counter to the goal. It brokers
*outbound* credentials/OAuth and registers *inbound* platform webhook triggers.
idfon's edge replaces bearer/OAuth with peer identity, and Connect is
Vercel-managed infrastructure — neither gives a transport nor a peer-identity
principal. It could still broker credentials for the agent's outbound
third-party calls, which is unrelated to this ingress.

## Deployment

Self-hosted only, for both the endpoint holder and the agent runtime.
Vercel-hosted Eve cannot hold the idfon endpoint; it already exposes its own
public authenticated HTTP surface, so idfon adds identity/consent there but not
the no-public-endpoint property.

## Slack mapping (reference)

For readers who know the Slack channel, the provider implements the same
channel contract with these substitutions:

| Slack channel surface | idfon channel surface |
|---|---|
| bot token / credentials config | idfon identity key + grant policy config |
| webhook route + `verifySlackRequest` signature check | endpoint accepts `idfon/message/1`; per-message `verify_message` + capability ticket |
| `channelId:threadTs` continuation token | `peer_id` (+ `conversation`) |
| `events` → Slack Web API post-back | `events` → `message.send` |
| `fetchFile` on authenticated Slack URLs | blob-ticket fetch (audio/video allowed, unlike Slack) |
| `auth` `AuthFn` → principal | verified peer key → `sessionAuth` |
| `auth`, `audience`, `turnPolicy`, `receive`, `deliver` hooks | identical |
| `slackContinuationToken(...)` | idfon's own token joiner |

Eve's Slack channel is webhook-based (a public `POST` route), not a poller; the
idfon provider is a different reachability class, not a reproduction of a Slack
pattern.

## Open questions

- **Principal mapping.** What `principalType`/`principalId` shape should a peer
  become, and how does it compose with an app's existing OIDC/user principals
  and per-caller connection lookup?
- **Multi-thread per peer.** Is `conversation` always populated, or one peer =
  one session by default? (The wire supports it either way.)
- **Attestation in split packaging.** How is the peer identity attested to the
  channel when the holder is a separate process (signed envelope vs a
  per-install secret)?
- **Media representation.** Extend `MessageContent` with a media variant, or
  keep the daemon's out-of-band ticket envelope?
- **Streaming replies.** Coalesce per turn (default) or emit progress via a
  live stream ticket?
- **Extension packaging.** Can the holder ship inside one Eve extension as a
  managed child, or must it be a separately deployed sidecar first?
- **Agent-to-agent.** Loop/rate guards, per-peer session isolation, and whether
  an agent's outbound idfon messages are a channel `receive` or a separate tool.
- **ACP overlap.** Is the idfon channel distinct from, or layered on, Eve's ACP
  support (stdio, local)?

## Chatting with an agent (CLI)

`scripts/eve-chat.sh` runs a real model-backed agent and chats with it
the same way you would with a human peer — `peer add`, `access allow`, `send`.
There are no agent-only verbs; the holder's capability ticket is the agent's
own ingress policy, supplied by the client only because that peer demands it.

```sh
scripts/eve-chat.sh --prompt "hello"          # one turn
scripts/eve-chat.sh                          # interactive, Ctrl-D to quit
scripts/eve-chat.sh --model openai/gpt-4.1-mini
```

The model is an AI Gateway id (`--model`, or `EVE_IDFON_MODEL`); unset in the
agent app it falls back to the deterministic `mockModel` the acceptance
scripts assert on. Turns thread to one Eve session per peer id automatically.

## References

- `docs/ai-voice-chat.md` — the voice agent built on this channel.
- `docs/idfon-eve-implementation-plan.md` — the milestone plan.
- `docs/agent-conversation-plane.md` — the conversation plane; the C1 bridge
  this supersedes for Eve.
- `docs/mcp-implementation-plan.md`, `docs/mcp-transport.md`,
  `docs/mcp-agent-report.md` — the tool axis and the bridge pattern reused here.
- `docs/protocol.md`, `docs/communication-model.md` — message plane, grants,
  operations.
- `docs/audio-media.md`, `docs/video-media.md` — live/blob media pipelines.
- `crates/idfon-core` (`transport.rs`, `lib.rs`) — agent-side endpoint,
  `serve`/`send`, `verify_message`, `verify_capability_ticket`.
- Eve channels: `https://eve.dev/docs/channels/overview`,
  `.../channels/custom`, `.../channels/slack`; extensions:
  `https://eve.dev/docs/extensions`.
