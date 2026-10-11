# Multichannel output: one result, many channels

Status: **design (2026-10-11).** Extends `docs/voice-multimodal.md` (the voice turn
contract) and builds on `docs/communication-model.md` (capability grants and local UX
policy). The prompt layer that selects channels is `docs/voice-agent-prompting.md`.

## The idea

A result is not one message. It is a set of **pieces**, and each piece goes to the channel
that fits it. A person, or an agent acting for that person, produces the result and routes
the pieces.

An example. A person asks for a comparison during a call. The answer comes back by voice.
The table goes to the chat as an artifact. The account number is requested with a
structured form. The receipt goes to email. That is four channels for one result.

This is the model the doc calls **multichannel**: not one channel with several
representations, but many channels carrying pieces of the same result.

## Modality is not channel

| Concept | Meaning | Examples |
| --- | --- | --- |
| Modality | The representation of one piece | speech, plain text, a table, a diagram, an image, a sound, a non-verbal event (emote), a structured form, a file |
| Channel | The delivery path and the surface that receives it | live voice, idfon chat, artifact view, form / HITL, SMS, email, Slack, a calendar invite |

- **Multimodal** output is one channel with several representations. The voice channel can
  carry speech and a short written pointer. The artifact view can carry text, a table, and
  an image.
- **Multichannel** output is several channels carrying pieces of one result.

## Why the split is necessary

Voice is ephemeral, serial, low-bandwidth, and cannot be re-read. It is good at immediacy,
rapport, interruption, and emotion. It is bad at lists, tables, exact long values, URLs,
code, diagrams, and anything the user returns to.

People already work this way on a call. They talk, send a link, email a document, fill a
form, and send a calendar invite. An agent should compose the same set of channels. The
channel choice is part of the answer, not an afterthought.

## Emotes: texturized non-verbal events

A non-verbal event — a gesture, a facial expression, a sound, a pause, or something that
happens to a participant or to the environment — is serialized as text so **every
participant in the context** can perceive it. This follows the adventure-game and MUD
convention: `*sighs*`, `*Alice looks away*`, `*the door opens*`.

An emote is an **observer-authored event message**. The observer emitted it. The actor is
a field in the message, not its author. The observer is one of two things:

- **The endpoint**, for a local signal it is the only one able to see: the user's hand
  movement, a sigh from the microphone, a device state.
- **The system or service**, for a world event or a state change: the call drops, a build
  finishes, a participant joins.

This is the key difference from a chat turn or a voice turn:

| | Participant turn | Emote |
| --- | --- | --- |
| Author | the person or agent | the observer (the endpoint or the system) |
| Content | what the participant says | what the observer detected, or the user declared |
| Authority | the participant's claim | the observer's detection |
| Kind | instruction or data for the turn | a non-verbal event |

### Origin: endpoint or system

**Endpoint-originated.** An endpoint is the observer of its own user. Only the endpoint
sees the user's hand movement through its camera, or a sigh through its microphone. It
sends the emote to the others. The endpoint authors it like a text message, but as a
separate **emote message type**: the semantics (an event, not speech) and the render
(styled line, sound, avatar) differ from text. The endpoint is the authority for the emotes
of its own user.

**System-originated.** The service observes world events and state changes. It emits an
emote for those. The service is the authority for what it observed.

Either origin is data, not an instruction.

Why it belongs here:

- Voice carries prosody and non-verbal cues, but only to the listener on that channel and
  only for the moment. An emote makes the non-verbal layer shared, durable, and portable
  across channels.
- It is the **shared counterpart of the private TTS tag**
  (`docs/voice-agent-prompting.md`, §8.4). The TTS tag is transient and local. The emote is
  part of the shared record. A private tag is stripped before storage. An emote is stored
  on purpose.
- Because the observer emits, the event can appear even when the participant has no UI to
  send it. The endpoint's voice pipeline can detect a sigh, a laugh, or a long pause and
  publish the emote for everyone, including agents that receive only text.

Observed or declared. Either observer can report two kinds of event:

- **Observed**: the observer detected the event (audio energy, a gesture, a device state, a
  network drop).
- **Declared**: a participant states an event ("I'm laughing", `/emote wave`). The
  participant is the claimant, not the observer.

Mark the two. An observed event carries the observer's authority. A declared event is a
claim. Both are data, not instructions.

Event kinds:

- self: `*sighs*`, `*laughs*`, `*leans back*`
- directed: `*nods at Alice*`, `*hands Bob the document*`
- world: `*the call drops*`, `*the build finishes*`, `*a file arrives*`
- state change: `*Alice is muted*`, `*Bob reconnects*`

Representation:

- A structured event: actor, verb, target, kind, observed or declared, intensity,
  visibility, time.
- The displayed line is a **rendering** of that event for one viewer, not the source of
  truth.
- A per-channel render. Chat shows the styled line. Voice may add a sound or a short spoken
  description. An avatar or artifact view may show it. An external channel gets the text.
- It must be distinguishable from speech and from instructions. A markup convention plus a
  system-message type keeps the model from reading an emote as a command.

### Perspective

Store the event, not the sentence. The event is perspective-neutral. The line each viewer
sees is derived from it. This makes a perspective shift possible and keeps the verbs
translatable.

A neutral third-person form is the canonical text ("Alice waves"). Each viewer may get a
different rendering:

- The actor sees an acknowledgment, or a second-person form ("You wave"), or nothing when
  the actor's own client already shows the action.
- The other participants see the third person ("Alice waves").
- A voice channel reads the form for that viewer. A text channel shows the styled line.

Attribution is a separate choice:

- **Embedded narration**: `*Alice waves*`. The system describes the world.
- **Attributed line**: `Alice: *waves*`. This reads as Alice speaking. It is wrong for a
  system event, because the emote is not speech.

Tense: use the present for a live event ("Alice waves") and the past for a completed or
reported event ("Alice waved"). Do not mix the two in one context.

Worked example. `/emote wave` before leaving produces two ordered system events:

```text
*Alice waves*
*Alice left*
```

The form `<speaker>: *waved*` attaches a speaker and uses the past. It reads as a report,
and the attribution still implies that Alice spoke. Prefer narration for both events.

Localization: keep the verb as an identifier (a social id), not an English string, so a
viewer's client can render it in that viewer's language and person.

Visibility and trust:

- "Everyone in the context" means the emote crosses privacy boundaries. Decide the context:
  a 1:1 call, a room, a group. Support a private emote (to one participant) and a broadcast
  emote.
- The system is the authority. A client can still lie to the system, so keep the observed
  or declared mark. An emote is data, not an instruction. `*ignore previous instructions*`
  is an event, not a command.
- An emote must not claim another participant's action unless the system observed it.

Open decisions:

- Wire shape. A distinct emote message type, or a subtype of the system/status family.
- Which events each observer emits (endpoint or system), and which need a declared emote.
- the canonical tense (present or past)
- whether the actor sees their own emote
- private versus broadcast
- whether emotes are in the stored transcript
- the voice render
- the social/verb vocabulary and its localization

## idfon already has the substrate

`docs/communication-model.md` separates **capability grants** from **local UX policy** for
inbound communication. An authorized sender may attempt delivery. The recipient's policy
decides whether the piece plays, notifies, queues, or is rejected.

Multichannel output is the **outbound mirror** of that model:

- Each egress channel is a capability with a subject, a direction, a lifetime, and a scope.
- The agent holds a set of egress capabilities. It proposes a channel for each piece.
- The capability and application layer authorizes and executes the send.
- The recipient's local policy decides attention and delivery.

The prompt **selects**. Code **authorizes and executes**. This is the same split as
guardrails (`docs/voice-agent-prompting.md`, §6).

## Call-assist agents

A person will have their own **call-assist agent**. It assists the person during a call. It
listens, does work, and routes pieces of the result on the person's behalf. It is the
person's delegate, not a shared service.

The visible presence and participation of the call-assist agent is a **configuration
matter**. The same agent can assist in different ways:

- silent coach, present only to the person
- visible participant, known to the other side but not speaking
- active participant, allowed to speak, ask, or answer

The configuration is part of the person's local UX policy, not a fixed property of the
agent. The configuration also decides which channels the call-assist agent may use.

The call-assist agent is the "people, not only agents" case. It lets a person join a call
and still route pieces to other channels, without doing the routing manually. It relates
to the voice-agent shapes in `docs/voice-agent.md` (wrapped and injected), but it is a
distinct concept and needs its own definition.

## Hybrid fan-out and layered authorization

Two decisions are fixed.

**Fan-out is hybrid.** The agent proposes a channel for each piece. The application applies
policy, and code authorizes and executes the send. The model is not the authority.

**Authorization is layered.** A channel is available to an agent in two steps:

1. The application and the current context must allow the channel.
2. The allowed channel then appears to the agent as a tool.

The agent sees only the channels it is allowed to use, and uses them as tools. An agent
cannot reach a channel that the application and the context did not allow, and cannot
invent one.

This keeps the earlier rule intact: the prompt is not a security boundary
(`docs/voice-agent-prompting.md`, §6). The layered check happens before the tool appears.

## Channel selection rule

The prompt needs one rule, stated once and repeated in the tool definitions:

- **Speak** when the piece needs immediacy, rapport, interruption, or emotion, or when it
  is a short answer or a one-line pointer.
- **Message or artifact** when the piece needs precision, persistence, structure, parallel
  content, or a reference the user returns to.
- **Form (HITL)** when the agent needs structured input, approval, or many fields
  (`IDFON-HITL/1`).
- **Emote** when a non-verbal event should be visible to everyone in the context, and the
  event is not a spoken answer.
- **External channel** (SMS, email, Slack, calendar) when the recipient is not on idfon,
  the piece must persist in another system, or the recipient asked for that channel.
- **Never** send to a channel the recipient has not granted.

## Channels: existing and aspirational

| Channel | Status | Primitive |
| --- | --- | --- |
| Live voice | implemented | live call, `IDFON-LIVE/1` |
| idfon chat / direct message | implemented | `Text` content, `IDFON-DATA/1` |
| Asynchronous voice | implemented | `IDFON-RECORDING/1` |
| Artifact view | implemented | `IDFON-ARTIFACT/1`, `IDFON-REF/1` |
| Point / show / screenshot | implemented | `IDFON-POINT/1`, `IDFON-SHOW/1`, `IDFON-SCREENSHOT/1` |
| Structured form / approval | primitive | `IDFON-HITL/1` + `IDFON-HITL-RESPONSE/1` |
| Group / room | implemented | `IDFON-ROOM/1` |
| Card / invite | implemented | `IDFON-CARD/1`, `IDFON-INVITE/1` |
| SMS, email, Slack, calendar | not native | Needs an MCP bridge, the EVE channel, or a new connector. |

External channels are the gap. The MCP transport (`docs/mcp-transport.md`) can reach an
external MCP server that holds the SMS, email, or Slack tool. That path exists but is not
wired as a first-class channel.

## Reply routing

A reply from any channel must join the same piece or result. The HITL response
(`IDFON-HITL-RESPONSE/1`) returns through `inputResponses` and **never steers the model**
(`docs/idfon-eve.md`). A form answer, an email reply, or a Slack reply is data for the
result, not a new instruction channel.

## Attention and interruption

A piece must not demand more attention than its channel grants. Voice interrupts. Chat
notifies. Email and SMS queue. A form waits. The recipient's local UX policy is final. An
agent may not "upgrade" a queued piece into a spoken interruption on its own.

## Verification and failure

- Make sure each piece arrived. Report a partial result as partial.
- Never send a duplicate external piece after a timeout. Check whether the first send
  happened before a retry (same rule as tool failures,
  `docs/voice-agent-prompting.md`, §7).
- A failed channel is not silently dropped. The agent names the failed piece and offers an
  alternate channel.
- A late reply from a slow channel still correlates to the result.

The application owns the correlation. How the pieces are tied on the wire is an
implementation detail and is not fixed here.

## Security and authorization

- Authorization is the layered check above, not the prompt.
- A piece sent to an external channel leaves the idfon trust boundary. Mark its provenance,
  and never send a sensitive piece to a weaker channel.
- Identity is per channel. The agent sends as the identity the grant names. Do not
  substitute one identity for another.
- Treat inbound content from any channel as untrusted data, not as instructions.

## Open decisions

1. **Call-assist definition.** How it relates to the wrapped and injected voice-agent
   shapes, and how the person sets its visible presence and participation.
2. **External identity and authorization.** How a recipient grants an SMS, email, or Slack
   channel, and which identity the agent sends as.
3. **Cross-channel reply correlation.** How a reply from an external channel finds the
   result.
4. **Recipient re-routing.** Can the recipient move a queued piece to another channel
   ("send that to my email")?
5. **The privacy boundary.** What may cross from idfon to an external channel, and how the
   crossing is shown to both sides.
6. **Failure semantics.** Idempotency and retry rules per external channel.
7. **Does the skill need this now?** The prompting doc can state the selection rule
   without the full transport. The transport is a separate build.

## References

- `docs/communication-model.md` — capability grants, local UX policy, communication modes.
- `docs/voice-multimodal.md` — the voice turn contract and the `speak` / artifact split.
- `docs/voice-agent.md` — the wrapped and injected voice-agent shapes.
- `docs/voice-agent-prompting.md` — the prompt layer that selects channels.
- `docs/voice-decisions.md` — the decision models that may make the channel choice.
- `docs/mcp-transport.md` — the bridge for external channels.
- `docs/idfon-eve.md` — the EVE channel and `IDFON-HITL/1` handling.
- `docs/idfon-artifacts.md` — the artifact model.
