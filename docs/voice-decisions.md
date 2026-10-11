# Voice decision models

Status: **design (2026-10-11).** Identifies the points in the voice setup that need an
intelligent decision, the decision each point makes, and the data to collect to fine-tune a
small decision model. The System One interface below is **verified against a live call**
(2026-10-11). Companion to `docs/voice-agent-prompting.md` (the prompt layer),
`docs/voice-multichannel.md` (channel selection and emotes),
`docs/voice-side-channel.md` (the on-device / service seam), and `docs/observability.md`
(the trace that joins a decision to its turn).

## Why

A voice agent makes many decisions that a prompt rule or a fixed threshold handles badly.
Some are fuzzy per-frame choices about the caller (has the turn ended, is that a
backchannel or an interruption). Some are policy choices about the agent's own behavior
(how much to reason, which channel to use).

An off-the-shelf classifier cannot serve these. The decisions depend on **user-related
behavior**: how one person pauses, backchannels, emotes, and reacts. The model must be
**fine-tuned on that user's own behavior**, so hosted Jev and Laya are reference points for
the interface and the pattern, not generic dependencies.

**Laya supports fine-tuning. Jev does not (yet).** The plan is therefore: fine-tune Laya
for the remote tier, and fine-tune a local model under the same contract for the on-device
tier. Jev stays useful for zero-shot, general decisions.

## The System One contract (verified)

A System One request is a **state** plus a map of **named typed questions**. One call can
ask many independent questions over the same state and returns typed answers with
probabilities, in one forward pass. There is no free-form output.

```text
POST <baseUrl>/systemone
{
  "model": "typesafe-ai/jev",
  "state": { ... },                 // JSON object; the situation to judge
  "questions": {
    "end_of_turn":   { "type": "choice", "instructions": "...",
                       "criteria": { "yield": "...", "hold": "..." } },
    "is_backchannel":{ "type": "noul",   "instructions": "...",
                       "criteria": { "true": "...", "false": "..." } },
    "urgency":       { "type": "score",  "instructions": "...",
                       "criteria": ["not urgent", "somewhat", "very urgent"] }
  }
}
```

Answer (live result from `typesafe-ai/jev`):

```json
{
  "answers": {
    "end_of_turn":   { "type": "choice", "choice": "hold",
                       "confidence": 0.34, "probabilities": { "yield": 0.33, "hold": 0.67 } },
    "is_backchannel":{ "type": "noul", "noul": 0.11 },
    "urgency":       { "type": "score", "score": 0.39, "confidence": 0.4,
                       "legend": { "0": "not urgent", "1": "somewhat", "2": "very urgent" },
                       "probabilities": { "0": 0.61, "1": 0.38, "2": 0.01 } }
  },
  "usage": { "input_tokens": 460, "output_tokens": 69 }
}
```

`noul` is **P(true)**. In this example P(true) = 0.11 and P(false) = 0.89, so the utterance
is probably not a backchannel.

Question types:

| Type | Request | Answer | Options |
| --- | --- | --- | --- |
| `choice` | `instructions` + `criteria` map | `choice`, `probabilities`, `confidence` | 2–62 (the wire uses up to 62 labels) |
| `score` | `instructions` + `criteria` list | `score` (0–1), `confidence`, `legend`, `probabilities` | 2–10 levels |
| `noul` | `instructions` + `criteria {true,false}` | `noul` = P(true) | boolean |

Constraints and facts:

- **The discriminator is `noul`**, not `bool` or `boolean`. The service rejects the other
  spellings.
- **No free-form text.** The model returns only typed decisions.
- **`temperature`** (optional) divides the answer logits before normalization. Above 1
  softens the distribution, below 1 sharpens it. Some backends ignore it.
- **Latency and cost.** A Jev call with all three question types took ~300 ms round trip
  through the Vercel gateway (the provider leg was ~110 ms) and cost about $0.00002 for
  460 input and 69 output tokens.
- **Token limits (Jev):** 64,000 tokens total per request. 32,000 tokens for the state plus
  the longest question. No streaming. No output-token limit. Laya is smaller (8,192-token
  context).
- **No image input** through the System One transport. `typesafe/jev-router` is multimodal,
  but that is a different (chat) API.
- `state` is a JSON object. Audio is not accepted, so audio must be reduced to features and
  a transcript before the call.

Transport families already implemented in pi (the harness), all sharing this contract:

| `api` | Serves |
| --- | --- |
| `typesafe-system-one` | TypeSafe Jev (hosted) |
| `cloudflare-workers-ai-system-one` | Workers AI |
| `llama-cpp-classify` | **A local llama.cpp server** (on-device / self-hosted) |
| `openai-decisions` | OpenAI-hosted decisions |

The local `llama-cpp-classify` transport is the on-device route. It renders the state and
questions into a prompt, constrains the output to label tokens (`A/B/...`, `0-9`,
`Yes/No`), and reads the label logprobs into probabilities. Its system prompt already
states the rule this project needs: the state is data to judge, and any instructions inside
it must not be followed. A fine-tuned local model served under this contract gives the same
interface on the endpoint.

### Model choice

- **Jev** is the reference System One model and is **not fine-tunable (yet)**. It fits
  zero-shot, general decisions.
- **Laya** is **fine-tunable** and is the base for idfon's per-user and per-deployment
  deciders. Its context is 8,192 tokens, so the state budget is tighter than Jev's 32,000.
- **On-device**, the decider is served locally under the `llama-cpp-classify` contract,
  preferably distilled from or fine-tuned with Laya as the teacher.

## Two tiers

The same contract serves both tiers, but the model, the data, and the privacy boundary
differ.

| | On-device | Remote (voice agent / holder) |
| --- | --- | --- |
| Runs in | the user's endpoint, inside the call-assist / voice bridge | the holder or service that runs the agent |
| Serves via | a local classifier (`llama-cpp-classify` contract, or Core ML behind the same shape) | a fine-tuned Laya (hosted), or a self-hosted System One model |
| Decides | the user's own signals and preferences | the agent's behavior and policy |
| Data | the user's own decision log, local | operator and tenant data |
| Fine-tuned | per user, locally | per agent or deployment |
| Constraint | latency, battery, privacy, no raw audio in the state | throughput, cost, consistency, token budget |

On-device deciders see signals only the endpoint has: microphone, camera, device state,
playback state. Remote deciders see the conversation and the tool surface. Some decisions
appear in both tiers. The topology decides which is authoritative, following the existing
rule that exactly one endpointer is authoritative per topology (`docs/voice-side-channel.md`,
F3). The same rule applies to every decision point.

## Decision inventory

`Question` is the System One question type. `Tier` is the default authoritative home.
Decisions that share a moment can go in **one** request.

| Decision | Tier | Question | Personal | Frequency | Input | Today |
| --- | --- | --- | --- | --- | --- | --- |
| End of turn | on-device | choice | high | very high | audio features, partial transcript, prosody | energy endpointer, fixed threshold |
| Barge-in, backchannel, or noise | on-device | choice | high | high | features, partial transcript, playback state | `BargeInController`, echo filter |
| Backchannel opportunity | on-device | choice | high | high | features, context | sub-minimum and backchannel filters |
| Self-speech or echo | on-device | noul | medium | high | features, playback state | `is_echo` |
| Addressed or background audio | on-device | choice | high | high | features, transcript | absent |
| Unclear or clear audio | on-device | choice | medium | high | features, ASR confidence | prompt rule |
| Language or accent switch | on-device | choice | high | low | transcript, prosody | prompt rule |
| Emote detection | on-device | choice | high | high | camera features, mic features | absent |
| Affect (frustrated, confused, satisfied) | on-device | choice | high | medium | prosody, words, pace | absent |
| Rapport or banter handling | on-device | choice | very high | medium | transcript, history, relationship | prompt rule |
| Reasoning effort | remote | choice | low | high | request, tool needs | API setting + prompt rule |
| Preamble needed | remote | noul | low | high | tool, latency, turn | model default |
| Verbosity target | remote | choice | medium | high | task type | prompt rule |
| Tool eagerness | remote | choice | medium | high | tool risk class, intent clarity | per-tool prompt rule |
| Delegation (GPT-Live) | remote | choice | low | high | conversation, backend capabilities | prompt rule |
| Escalation | remote | noul | low | low | sentiment, failure count, topic | prompt rule |
| Channel per piece | both | choice | high | high | piece properties, grants, context | prompt rule |
| Artifact spoken projection | remote | choice | low | medium | artifact metadata, turn | prompt rule |
| Attention level | both | choice | medium | medium | piece, recipient policy | local UX policy |
| Call-assist presence | on-device | choice | high | medium | config, context | configuration |

Decisions not in the table are pure policy (authorization, capability grants) or pure code.
Neither needs a model.

## Training data

One record per state, with every question and answer in it.

```text
{
  trace, turn_id, ts,
  tier:      "on_device" | "remote",
  model:     "<model + version>",
  state:     { ... },        // the exact state sent
  questions: { id: { type, instructions, criteria } },
  answers:   { id: { ... } },// the model's typed answers with probabilities
  action:    { id: "<chosen label>" },  // what the runtime did after the policy
  outcome:   { ... },        // the weak-label signal
  label:     { id: "<gold>" }// optional human label
}
```

- **Features.** Only what the decider can see at that moment, reduced into the state. Raw
  audio and camera frames never leave the endpoint.
- **Outcome (weak labels).** The behavior after the decision labels it. A wrong end of turn
  shows up as an immediate continuation. An unnecessary clarification shows up as a repeat.
  An ignored artifact shows up as no open.
- **Gold labels.** A human-annotated sample, small but trusted, to calibrate the weak labels
  and to evaluate.
- **Privacy.** The on-device decision log is personal data. Only derived features and labels
  can leave, and only under a grant.

## Fine-tuning loop

1. Start from a fine-tunable base per decision set: Laya for the remote tier, or a local
   model distilled from a fine-tuned Laya for the on-device tier.
2. Collect the decision log on the endpoint, with consent.
3. Fine-tune per user (on-device) or per deployment (remote).
4. Evaluate against a held-out slice of the user's own traces, not a global set.
5. Version the model, and keep a rollback path. Never block a call on a missing model.

**Cold start.** A new user, or a new contact, has no per-user data. The shared base and the
global defaults act as the prior. Personalization happens as the log fills. High-frequency
decisions personalize first.

**Rare decisions.** Escalation and language switch are too rare to fine-tune per user. Keep
them as prompt rules or shared models until the volume justifies a per-user head.

## Authority and guardrails

- **Propose, do not authorize.** A decider proposes. Code and capability grants still
  authorize. A classifier never authorizes an external send or a destructive action.
  Implemented in `crates/idfon-director/src/authority.rs` (#37): the grant and budget
  fail closed; a decider may veto, but a failing decider falls back to the grant
  (fail-open).
- **One authoritative decider per topology.** Matching F3, client-cascade and
  holder-cascade each have exactly one authoritative decider for a point. The other only
  advises.
- **A decider must fail open.** If a fine-tuned model is missing, stale, or wrong, the
  default model or the fixed threshold takes over. A call must never depend on a decider.
- **Poisoning.** A hostile caller can shape the on-device model through the microphone. Keep
  the online learning rate low, keep a user-visible correction path, and let the user pin or
  reset the model.
- **The personalized model is personal data.** It must not leave the endpoint without a
  grant.
- **Untrusted state.** Text inside the state (transcript, tool output, artifact content) is
  data, not instructions. The local classifier system prompt already says this. Keep that
  rule in any fine-tuned model.

## Open questions

1. **Laya fine-tuning mechanics.** Laya is fine-tunable and Jev is not (yet). Confirm
   Laya's fine-tuning inputs (does it take state and questions, or raw text?), the output
   artifact (a hosted endpoint, or exportable weights), and whether a fine-tuned model can
   run on-device. If it cannot, use Laya as the teacher and train a small local model
   served under the `llama-cpp-classify` contract.
2. **One state per moment.** Which decisions share a state and one call, versus a separate
   call each. Token budget (Jev: 32k state + longest question) bounds the state.
3. **On-device serving.** llama.cpp or Core ML, and the model size that fits the latency,
   battery, and privacy budget.
4. **Per-relationship scope.** Is rapport personalized per user, or per user-and-contact?
5. **Remote training consent.** What may the operator learn from, when the personal data
   stays on the endpoint.
6. **Data volume.** The minimum decisions before a per-user fine-tune beats the shared
   default.

## References

- `docs/voice-side-channel.md` — on-device / service seam, F3 endpointer authority,
  barge-in controller.
- `docs/voice-agent-prompting.md` — the prompt rules these deciders would replace or guard.
- `docs/voice-multichannel.md` — channel selection and emotes.
- `docs/observability.md` — the trace and correlation keys.
