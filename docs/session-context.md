# Session as medium, agent-owned virtual context

> **Status: design (2026-10-05).** Supersedes `chat-session.md` (deleted) and
> the app-supplied recall line of work. idfon does **not** treat an agent's chat
> log as the model's context: a session can carry several agents, so the session
> is only the **medium**. Each **agent loop host** owns its own **virtual
> context**, edits it as it likes, and is influenced by other agents only
> through their responses and behavior. The multimodal voice-chat host owns the
> voice-chat context. Model output is split by tool: `speak` for the spoken
> response, artifact tools for written or drawn output.
>
> Read with [`idfon-eve.md`](idfon-eve.md) (session model),
> [`voice-multimodal.md`](voice-multimodal.md) (turn contract and output
> routing), and [`idfon-artifacts.md`](idfon-artifacts.md).

## Definitions

- **Session** — the ordered, signed message stream among participants. It is the
  transport and the record. It is **not** the model's context.
- **Agent loop host** — the runtime that runs one agent's loop and owns that
  agent's virtual context (e.g. the Eve app holding a voice chat).
- **Virtual context** — the state a host injects into its own model as context
  for a turn. Owned and maintained by that host alone.
- **Participants** — the user (via the app), the voice agent, and any target
  agent(s) in the session.
- **Voice agent** — bridges audio and text: transcribes caller audio to text and
  synthesizes text to audio. It is the TTS side of `speak`, and likely both
  calls `speak` (to emit speech) and answers it (to synthesize for others).
- **Non-voice agent** — text in, text out only; it neither hears audio nor
  speaks.
- **Multimodal agent** — may both speak and display in the same turn (call
  `speak` and the display/artifact tools together).

## Model

1. **Single writer per context.** Only the owning host edits its virtual context.
   Its agent may edit it however it wants.
2. **Influence is indirect.** An agent affects another agent's virtual context
   only by influencing the owner through its response and behavior over the
   session — never by editing that context directly.
3. **The multimodal voice-chat host owns the voice-chat context.** It decides
   what to keep, how to shape it, and how another agent's response is folded in
   (or not).
4. **No sharing hazards to design around.** No cross-agent edits, no permissions
   matrix, no merge or last-writer-wins problem. The only regular maintenance is
   **context compaction**, and that is each host's own responsibility.
5. **A turn's model input is the host's current virtual context** plus the turn
   itself. The session log is not the model's context.

## Output split (normative)

The model returns tool calls, not a single blob:

- **`speak`** — the spoken response, kept short. It sends the text plus
  accompanying metadata as a session message addressed to a TTS-capable
  recipient (typically the voice agent). That recipient synthesizes the audio
  and forwards it to the user over the existing audio stream, and the app plays
  it back. The calling agent does **not** need TTS of its own, and `speak` does
  not play locally.
- **artifact tools** — any written or drawn output (long text, tables, diagrams,
  charts, pages). These never go through `speak`.

The model decides, per turn, what to say versus what to publish. This is the
agent's output contract; [`voice-multimodal.md`](voice-multimodal.md) covers the
matching input contract for a turn.

`speak` metadata carries what the synthesizer and player need (voice, language,
rate, interruption/barge-in priority, correlation id); the exact set is an open
question below. Any agent that should be heard calls `speak`; the voice agent
does the transcribe/synthesize work. A non-voice agent only produces text and
never calls `speak`.

## What this replaces

- `chat-session.md`'s fresh-session/rotate framing and app-supplied recall.
- `recall_session`, `priorSessionContext`, and any transcript-as-artifact idea.
- Treating `ChatStore` / `SessionStore` as model memory. They remain the
  user-visible session log only.

## Resolved (all host-internal, not cross-agent)

- **Representation.** Typed entries (key → string), scoped to the durable
  session id. Implemented in `context-store.ts`.
- **`speak`.** `IDFON-SPEAK/1` envelope emitted to the per-session outbox
  (`extension/outbox.ts`) and appended to the reply by the channel at
  `message.completed`, metadata `{text, voice, language, rate, priority,
  correlation_id}`. The TTS-capable voice agent consumes it; agents that never
  call `speak` keep speaking their reply text. `point` and `show` use the same
  emit path. Implemented.
- **Folding.** The owner decides. The injected context instruction tells the
  agent to record durable decisions/results, including anything another
  participant's response changes. No target agent receives the owner's context;
  influence is indirect (model rule 2).
- **Compaction.** Bounded store (32 entries / 2 KB value / 8 KB total) evicts
  oldest on write, plus an explicit `context_edit action=compact` (`keep`
  optional). The host owns the policy.
- **GPT-Live `speak`.** A native-duplex call speaks its own turns directly; a
  delegated reply's `IDFON-SPEAK/1` is honored by feeding its text to the live
  commentary (`speak_text` in `eve-idfon`).

## Code impact

- **Reverted (done 2026-10-05).** `priorSessionContext` / `lastCallTranscript`
  recall usage, `resumeLast` / `resumeContext`, and the Resume affordances are
  removed; `ChatStore` and `ChatViewController` are back to their pre-recall
  state.
- **Kept as a guard.** `IDFON-SESSION/1 action=rotate` still clears the Eve
  model history per call so the session log is never treated as context; its
  long-term shape is an open question above.
- **Done (2026-10-05).** Host-owned virtual context: `extension/context-store.ts`
  (single-writer, session-keyed, bounded, `compact`), `tools/context-edit.ts`
  (`get`/`set`/`delete`/`list`/`compact`/`clear`), and `instructions/context.ts`
  (per-turn injection + folding guidance). Registered in the built extension.
- **Done — `speak`.** `extension/tools/speak.ts` returns an `IDFON-SPEAK/1`
  JSON envelope (`text` + `voice`/`language`/`rate`/`priority`/`correlation_id`).
  Consumers take the spoken form from it, falling back to the stripped reply so
  agents that never call `speak` are unchanged: the holder cascade and GPT-Live
  commentary (`speak_text` in `idfon-voice-agent` and `eve-idfon`; test
  `speak_text_prefers_the_speak_envelope`), and the app (`SpeakEnvelope` +
  `VoiceAgentSession.spokenText`). The envelope is stripped from display, not
  shown as a chat bubble.
- **Complete.** No open implementation items in this doc: recall/resume are
  reverted; context, folding, compaction, `speak`, and GPT-Live commentary are
  implemented. The `IDFON-SESSION/1 action=rotate` guard stays until the context
  store fully displaces session-log influence.

## References

- `integrations/eve-idfon/extension/channels/idfon.ts` — session medium,
  address → session, envelopes.
- `integrations/eve-idfon/extension/instructions/voice-pipeline.ts` — what is
  injected into a turn today.
- `agents/gpt-live-1/agent/tools/voice-reply.ts` — the current spoken-reply tool
  the `speak` contract would generalize.
- [`voice-multimodal.md`](voice-multimodal.md),
  [`idfon-artifacts.md`](idfon-artifacts.md), [`idfon-eve.md`](idfon-eve.md),
  [`voice-agent.md`](voice-agent.md).
