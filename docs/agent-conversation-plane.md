# The Agent Conversation Plane — Scoping

> **Status:** scoping only; no code. Follow-up to
> `docs/mcp-agent-report.md` (design) and `docs/mcp-implementation-plan.md`
> (M1–M5, implemented). Written 2026-09-13.

## The gap

"Use idfon to talk to an AI agent" has two halves:

- **Doing** — tools, remote servers, device capabilities. Covered by MCP:
  `idfon/mcp/1` transport (`crates/idfon-mcp`, daemon relay), the
  `idfon-mcp-server` adapter, contact tickets, and grants. Implemented.
- **Talking** — turns, replies, streaming, voice. **Not implemented.** What
  exists is a transport and a tool surface; there is no conversation model, no
  agent runtime, no chat UI for an agent contact.

The report called this the **Conversation** plane and proposed ACP as a
vocabulary donor. This document scopes the smallest thing that makes "talk to
an agent" real, and lists the decisions that need answers before code.

## What already exists (reuse, do not rebuild)

- **Agent as peer.** An agent is an iroh endpoint with its own key, added as a
  contact (`peer add`, contact ticket). Its identity is separate from the
  user's by design.
- **Text messages.** `message.send` / message receive already carry addressed,
  authenticated, persisted text between peers. A conversation is, at minimum,
  a stream of these.
- **Tool access.** The agent's compute loop calls MCP servers — remote ones
  over `idfon/mcp/1`, and local idfon capabilities via `idfon-mcp-server`
  (grant-gated). Conversation does not need to be an MCP method.
- **Consent.** Grants gate the agent's use of idfon capabilities. Conversation
  itself is peer messaging, already gated by `message.send` / `message.receive`.
- **Discovery.** A contact ticket already carries the agent's cached
  `server/discover` (transport + capabilities + identity).

## Key insight: conversation is messaging, not a new transport

An agent is a peer with a compute loop behind it. The user sends a message; the
loop reads it, calls tools, and sends a reply. That is the existing message
plane. **No protocol change is required for a minimal chat.**

The MCP binding is *how the agent reaches tools*. Conversation is *how the user
and the agent exchange turns*. They are orthogonal and should stay so — do not
smuggle turns into MCP methods, and do not make `idfond` understand either.

## Decisions to resolve (before implementation)

| # | question | candidate default | why it matters |
|---|---|---|---|
| C1 | Is an agent runtime in-repo, or is idfon only the pipe? | idfon provides the pipe; the agent runtime is external (a reference template ships) | keeps `idfond` free of LLM/tool semantics; matches the report's coupling rule |
| C2 | Whole messages or token streaming? | **whole messages first** | the report explicitly says token streaming only if whole messages are insufficient; message store is already durable |
| C3 | Turn semantics: plain messages, or an explicit turn/session id? | thread by peer + an explicit `conversation_id` in message metadata | enables multiple threads per agent and future ACP mapping without a new transport |
| C4 | Does conversation use ACP shapes? | ACP as an adapter later, not the base | framework integration via MCP already matters more than ACP conformance |
| C5 | How does the agent know it is addressed in a conversation vs a tool call? | separate channels: MCP tools are the agent's outbound; inbound peer messages are conversation | avoids conflating "user said hi" with "an MCP request arrived" |
| C6 | Streaming/partial replies | defer; if needed, MCP-style notifications on the message stream, not a new protocol | the report's "token-streaming chat if whole messages work" is out of scope |
| C7 | Voice/conversation media | defer to the media workstream (report step 6) | modality negotiation is its own design |
| C8 | Prompt-injection containment | only the agent's own conversation thread enters its context; never the inbox/contact graph | load-bearing risk from the report |

## Proposed minimal path

Each step is independently useful and leaves no dead protocol surface.

1. **C0 — zero-code validation.** Script an agent adapter over `idfon events
   --follow` + `idfon send` (the report's roadmap step 1) and confirm a
   model-backed peer converses acceptably. No core or protocol change.
2. **C1 — reference agent runtime.** A small out-of-tree (or `examples/`)
   process that owns an `idfon-core` endpoint + key (the same embedded-node
   shape as `idfon-mcp`), reads addressed messages, runs a loop with MCP tool
   access, and replies. This is the "agent" a user adds as a contact.
3. **C2 — conversation id + thread display.** Add an optional
   `conversation_id` to message metadata and surface agent threads in the
   CLI/GUI, if C0 shows plain messages are not enough.
4. **C3 — ACP adapter.** Only if a concrete framework needs ACP shapes; maps
   turns onto the C2 thread.
5. **C4 — voice.** Rides the separate media/voice workstream; transcript-first.

C0 is the gate: if a scripted agent over plain messages is pleasant, C1 is the
whole feature and C2–C4 stay deferred.

## Out of scope for this plane

- An LLM or MCP runtime inside `idfond`.
- Token streaming unless C0/C1 prove it necessary.
- A global agent/tool directory.
- Act-as-user delegation; agent-to-agent (needs loop/rate guards first).
- Full ACP conformance.

## Open questions

- Does an agent expose a *presence* (online/typing) and do we model it, or is
  it best-effort like today's messaging?
- Are agent conversations durable and searchable the same way peer messages
  are, or ephemeral by default?
- Who owns the transcript when voice is involved (control plane vs media)?
- Is `conversation_id` a message-metadata field or a first-class store object?

## References

- `docs/mcp-agent-report.md` — three planes, voice negotiation, risks,
  roadmap.
- `docs/mcp-transport.md` — the `idfon/mcp/1` binding.
- `docs/mcp-implementation-plan.md` — implemented M1–M5 and follow-ups.
- `docs/communication-model.md` — message delivery and grants.
