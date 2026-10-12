# Voice agent multimodal turn contract

> **Status: design (2026-10-05).** Defines what one voice turn carries and where
> long content goes. Companion to [`session-context.md`](session-context.md) (the
> session medium and shared virtual context) and
> [`idfon-artifacts.md`](idfon-artifacts.md) (the artifact model). Read with
> [`voice-agent.md`](voice-agent.md) and [`live-voice.md`](live-voice.md).

## Principle

A voice turn is **text + envelopes + at most one attachment**, and the model's
system prompt owns routing. The per-turn `context` stays a thin text signal
(engine state, app-supplied recall); structured payloads ride as envelopes and
attachments, which is already the pattern (the app's `MessageBody.parse`
separates a preamble from trailing `IDFON-*/1` envelopes).

## The turn

| Part | Carrier | Example |
| --- | --- | --- |
| Spoken input | turn text | the ASR transcript of what the user said |
| Thin context | `message.send context` / live `context_b64` | on-device engines, app-supplied prior session |
| Reference | `IDFON-REF/1` envelope | artifact + `blob_ticket` + selector (text/region/time) |
| Visual input | turn attachment | the app's crop of the tapped region, or a live camera frame the agent requested |
| Other payloads | `IDFON-*/1` envelopes | recordings, files, artifacts |

### References and multi-input correlation

The user opens an artifact, taps a region, and talks about it. The app sends the
transcript plus an `IDFON-REF/1` (identity, `blob_ticket`, selector) and, for a
region, the cropped pixels as the turn attachment. The prompt tells the agent to
resolve the reference with `read_reference`
(`agents/gpt-live-1/agent/tools/read-reference.ts`) before answering, and to
correlate "what was said" with "what was tapped" — the tap is not a separate
question.

### Camera as input (planned, 2026-10-11)

An idfon app that has a camera exposes it as a device capability. A remote agent
requests camera use; the app captures frames with the same `CameraPusher` path
as a video call ([`video-media.md`](video-media.md)) and returns them as a
follow-up turn. The request is scoped **per contact**. The app grants or denies
it, so camera use is a capability/authorization decision, not a prompt rule. A
turn can then carry speech, a press, and a live camera frame together; the
prompt treats them as one question (`docs/voice-agent-prompting.md` §13.4).
Frames from a caller device are untrusted data.

The director implements the turn as one joined prompt (`crates/idfon-director/src/turn_input.rs`,
#39): the transcript, the `IDFON-REF/1` references, and the attachments render
into one question. The model resolves a reference with `read_reference` over a
`ReferenceResolver` seam. A camera frame renders only under the `camera` grant.

**On-device turns have no resolver.** An app-local agent (AFM 3,
`docs/voice-agent-modes.md`) runs a model that cannot call `read_reference` and
see the result — the AFM provider ends the turn after one tool call — and the
apps pass no `ReferenceResolver` over the FFI. So the app resolves what it can
before the turn and the reference's own content rides in the prompt: a
`text`/`element` selection carries its selected text in the selector's `quote`
(the field is documented for exactly this), which the loop renders inside the
untrusted-data block. When the app replies to a reference, it sends the
reference this way (`ChatViewController.turnInput`). An image `region` or a
`time` range has no text to carry and needs an image/audio path into the
model; until that exists an app-local agent sees the selector, not the pixels.

**Text files are the one attachment kind that can reach such a model**, because
the shell reads them and the loop inlines the content: the app reads the file
(`OnDeviceAttachments`, capped at 32 KiB) and sends it as
`Attachment::Text { name, content }`, which renders as `[file] <name>` inside
the data block. The loop bounds it again at `MAX_TEXT_ATTACHMENT_BYTES` (64 KiB)
and marks the cut, so a shell that forgets to cap cannot blow the context. A
binary file is refused with a message rather than sent as mojibake, and a file
turn is recorded as words in the thread, not as a downloadable bubble: a local
agent has no blob to download.

**What "attachment" means per kind today** (the model never fetches bytes
itself; the shell or the agent does):

| Kind | Remote agent | App-local agent |
| --- | --- | --- |
| Text (reference quote, text file) | ticket + `quote`; the agent resolves | inlined in the prompt |
| Image (region crop, camera frame) | blob ticket staged for the agent's own tools — whether a given model sees the pixels is unverified | region crop rides as an image content part |
| Audio (voice memo) | blob ticket, the agent's speech path handles it | not wired: no audio path |

**Images travel as content parts.** `Attachment::Image { name, mime, data }`
(base64, `Content::Image`'s encoding) becomes a `yoagent` `Content::Image` part
beside the prompt, so any provider that takes images can use it — not just AFM.
The prompt additionally describes every image (`[image] <name> (<mime>, N
bytes)`) inside the data block, so a model that cannot take one still knows
what was pointed at. An image the API cannot take — unknown type, over
`MAX_IMAGE_ATTACHMENT_BYTES` (4 MiB), or undecodable — is left out of the parts
and only described: an image must never fail the turn.

On Apple that path is exact: the AFM provider answers image turns with
`Session::respond_with_attachments`, and falls back to the text-only structured
call when the OS or model reports no image capability
(`UnsupportedPlatform`/`UnsupportedCapability`). The attachment call is not
schema-forced, so the provider ignores a tool call whose name is not one the
loop registered — the model improvises tool names from what it sees in the
prompt, and dispatching one would kill the turn.

Verified on the host (`cargo run -p idfon-director --features afm --example
afm_probe -- <image.png>`, macOS 27): a 128×128 PNG with a red circle attached
to an otherwise image-free prompt came back as *"It contains a red circle"* in
1.55 s — pixels, not just metadata.

## Client-facing tools

The multimodal surface is a set of tools in `eve-idfon`, so any idfon-aware
agent gets them and chooses dynamically. A tool **emits** its envelope to a
per-session outbox (`extension/outbox.ts`); the channel appends the queued
envelopes to the reply at `message.completed`, in tool-call order. Delivery does
not depend on the model echoing the envelope, and the client sees one reply with
the effects ordered.

| Tool | Envelope | Effect |
| --- | --- | --- |
| `speak` | `IDFON-SPEAK/1` | TTS recipient synthesizes and streams audio to the user. |
| `point` | `IDFON-POINT/1` | App opens the artifact and highlights the selector. |
| `show` | `IDFON-SHOW/1` | App opens the artifact. |
| `add_artifact` | `IDFON-ARTIFACT/1` | Publishes bytes as a durable artifact the user opens. |
| `render` | `IDFON-RENDER/1` | Shows a small interactive view the app draws natively from its own components (`docs/reply-blocks.md`). |
| `screenshot` | `IDFON-SCREENSHOT/1` | Requests a screenshot; the app captures its window and sends it back as a follow-up turn. |
| camera tool (planned, name not fixed) | — | Requests live camera use on a capable app; the app captures frames and sends them back as a follow-up turn, scoped to the per-contact grant. |
| `context_edit` | — | Edits the host-owned virtual context ([`session-context.md`](session-context.md)). |

A cancelled or failed turn drains (discards) its outbox so effects never leak
into a later turn. The extension implements these tools; the app renders
`IDFON-POINT/1`/`IDFON-SHOW/1` (image region, text selection, HTML element or
media time) and answers `IDFON-SCREENSHOT/1` on iOS and macOS. `add_artifact`
lives in the extension now, so any idfon-aware agent can publish artifacts; the
remaining agent-specific tools (`send`, `put`, `issue-card`) still use the
model-echo pattern and can move to the outbox the same way.

## Output routing

The model returns tool calls, not one blob:

- **`speak`** — the spoken response, kept short and conversational. It sends
  the text + metadata as a session message to the TTS-capable recipient (the
  voice agent), which synthesizes and forwards audio to the user over the
  existing audio stream for the app to play. The model must not read out long
  text or narrate an image.
- **artifact tools** — long text, tables, diagrams, charts, images, pages
  (`add_artifact` / `IDFON-ARTIFACT/1`), with at most a one-line spoken pointer.

The model decides per turn what to say versus what to publish. Non-voice agents
produce text only; the voice agent bridges audio↔text and is the TTS side of
`speak`; a multimodal agent may call `speak` and the display/artifact tools
together in one turn. This is a prompt contract, not a transport concern.
## Session interplay (kept orthogonal)

| Concern | Owner |
| --- | --- |
| Context | the shared virtual context, edited through the session ([`session-context.md`](session-context.md)) |
| References | `IDFON-REF/1` + crop attachment |
| Spoken output | the `speak` tool → session message to the TTS recipient |
| Written/drawn output | artifact tools |

## Full-duplex (decided)

`read_reference` and `add_artifact` are Eve tools, so only the LLM/cascade path
can call them. A native-duplex (GPT-Live) call runs a WS model with no tools,
so it cannot resolve a reference or see a crop itself.

**Decision: a reference turn is delegated, never resolved inline.** The tap
(text + `IDFON-REF/1` + crop) is delivered to the session's Eve agent, which
resolves it with `read_reference` and returns its reply/artifact; a delegated
reply's `IDFON-SPEAK/1` reaches the live commentary. The full-duplex model only
speaks the returned commentary.

**Delivery:** use the normal session message path, not a new live control. The
app sends the ref turn as an ordinary message (text + `IDFON-REF/1` + crop
attachment) to the holder; during a native-duplex session the holder bridges
that turn to the Eve agent and routes its reply to the live commentary. The
`IDFON-LIVE/1 action=text` control stays text-only. **Status:** design fixed;
the holder-side bridge is the one remaining implementation (needs device
testing), tracked here rather than left as an open question.

## Decisions

- A reference turn on a native-duplex call is delegated; never resolved inline.
- The crop is the turn attachment, not an artifact.
- The reference turn uses the normal session message path, so the wire already
  carries everything (`MessageEnvelope` text + envelopes + attachment).
- Camera is an app-side capability. A remote agent requests it; the app grants or denies per contact. A live frame is a visual input, like the crop attachment.
- No recalled prior session (removed with [`session-context.md`](session-context.md)).
- Prompt wording for multimodal routing is out of scope; this doc fixes the
  contract and ownership.

## References

- `integrations/eve-idfon/extension/channels/idfon.ts` — envelope handling,
  `MessageBody.parse`.
- `agents/gpt-live-1/agent/tools/read-reference.ts` — reference dereferencing.
- `crates/idfon-voice-agent/src/lib.rs` — `caller_text_control`,
  `live_call_context`.
- `crates/idfon-voice-agent/src/gpt_live.rs` — delegation → commentary, session
  instructions.
- [`idfon-artifacts.md`](idfon-artifacts.md), [`session-context.md`](session-context.md),
  [`voice-agent.md`](voice-agent.md), [`live-voice.md`](live-voice.md).
