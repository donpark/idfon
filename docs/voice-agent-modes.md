# Voice agent modes

How a caller talks to an agent, and where the latency goes. Measured on
iPhone 16 / iOS 27.0.1 (`docs/voice-agent-harness.md` §5).

## The three modes

| Mode | Path | Latency per turn | When |
| --- | --- | --- | --- |
| **On-device agent** | STT → AFM3 loop (on-device) → TTS | ~1.5 s warm, **no network** | Private, offline, low-latency chat. Battery cost. |
| **Passive remote** | STT → wrapped agent (LLM) → TTS | remote round trip (~1.5–3 s) | The wrapped agent's knowledge/tools matter |
| **Proxy** | STT → AFM decides → wrapped agent → TTS | on-device turn **+** remote round trip (~3–5 s) | Per contact, when the voice layer has its own agency |

A turn can also carry parts: an artifact selection, a text file, or a region
crop as an image. Only AFM reads them locally; a remote agent gets a ticket and
its own tools decide (`docs/voice-multimodal.md`).

**Default is passive remote.** The holder (`live-voice-agent`) injects the live
config's `instructions` into the turn, so a plain text agent answers as a voice
agent without editing its own prompt. No LLM sits in front of the content.

**Proxy is opt-in, per contact.** It exists for modes where the voice layer
does something with the turn (intermediary, judge, interpreter) or has its own
tools. For passive conversation it only adds latency and failure modes (it
re-paraphrased a question, and its greeting echoed into the transcript). Set it
in the contact's detail screen (iOS) or the peer-details popover (mac), under
"Voice turns › Mode"; `-directorcall` forces a proxy call on any contact, as the
device probe for this path.

**On-device is per contact.** The AFM3 loop answers directly, so there is no
network. AFM3 has no tools and no live data; it chats and knows what it was
trained on (and can see an attached image on 27). Use it for a private/offline
assistant, not for a knowledge agent. Added as a contact in the app
(`OnDeviceAgents`); the launch flags below are probes only.

## Cost and the free tier

Cost is a first-class axis of the mode choice (2026-10-21): **every off-device
turn costs money** — hosted ASR, the wrapped agent's LLM, hosted TTS, and the
server running the engine — while an on-device turn costs only battery.
On-device voice agents are what make a free tier possible.

| Mode | Cost per turn |
| --- | --- |
| On-device agent | none (battery only) |
| Passive remote / Proxy | hosted ASR + the wrapped agent's LLM + hosted TTS |

Consequences:

- **The free tier runs the on-device cascade** — on-device ASR/TTS
  (Parakeet/Kokoro/Apple) + the on-device decision model (the tyger port) + an
  on-device agent or a local wrap. No marginal cost per turn; the tyger
  turn-taker is what makes the free tier's experience good rather than merely
  cheap.
- **Off-device voice is the paid tier** — the quality of its models and its
  wrapped agents' knowledge justify the per-turn cost.
- Engine selection is therefore **tier-aware** alongside the
  `auto|classic|tyger` knobs (`voice-tyger-option.md`): `auto` prefers
  on-device services whenever they are available and only routes a turn
  off-device when the tier calls for it (or a contact's Mode demands a wrapped
  remote agent).
- The iroh voice pipe keeps both directions open: a paid off-device agent can
  borrow on-device ASR/TTS/sensors to cut its own cost while staying in
  control of the conversation, and the free tier never has to leave the phone.

## Contact screens show the truth (2026-10-21)

A contact screen must display **what is actually being used** for that contact,
even when it differs from the user's preference — truth over preference, so a
support question ("what is my call running on?") is answerable at a glance.

What every voice-capable contact's screen shows:

| fact | values | source |
| --- | --- | --- |
| **voice source** | `native` — the contact answers voice itself (e.g. AFM 3, an on-device agent with its own voice loop) · `wrapped` — a voice agent speaks for it (the wrap config) · `none` | the contact model: a contact is voice-enabled either by implementation or by being wrappable **without conflict** — both read as voice-capable, and the screen says which |
| **active pipeline** | the engines a call actually uses (e.g. `Deepgram + ElevenLabs` server-side, or `Parakeet + Kokoro` on-device) | the live engine's declaration (`/voice/info` — server options) + the call plan (`serverCascade` vs on-device); the client-side options the holder lists are shown as *capabilities*, labeled `side: client` |
| **turn model** | `classic` / `tyger` (the `Voice turns` row, `voice-tyger-option.md`) | the per-contact override, else the resolved default |

The screen shows the pipeline resolved **for that contact now** (plan + engine
+ turn model), not the global defaults; if the app is offline from its engine
it says so rather than showing a stale preference.

## On-device agents are app-local contacts

The built-in **AFM 3** is seeded when the OS ships that model (**iOS/macOS
27+**). Users add more on-device agents as ordinary contacts, each a **name
plus a prompt** (`instructions`) — used like `llm` agent instances: the same
local model, a different role per contact. No daemon peer, no network. Stored
locally (`ios/Idfon/OnDeviceAgents.swift`, the mac twin under
`mac/Sources/Idfon/`); text and voice both run through `OnDeviceAgentRunner`.
AFM 3 cannot be deleted. Both shells merge them into the contact list and
title their threads and calls by name (`LiveActivityController`). A turn can
point at an artifact selection, carry a text file (inlined into the prompt),
and carry a region crop as an image — AFM 27 takes images, so the local model
sees the pixels. Audio still has no path into a local model
(`docs/voice-multimodal.md`).

This is distinct from the per-process `-directorondevice`/`-directorcall`
launch flags, which are device probes: they must not change how a real contact
behaves in normal use. A real contact's turn mode is the per-contact setting,
stored with the other per-contact voice settings (`ContactVoiceTurnModes`).

## Fast judgments are not an agent

Turn-taking, barge-in, echo suppression, and prompt injection are **code**.
Backchannel detection is `ios/Idfon/TurnController.swift` — a deterministic,
fail-open policy with a runnable check
(`ios/Checks/TurnControllerCheck`).

A **decision model** (SystemOne `noul`/`choice`/`score`, `docs/voice-decisions.md`)
may replace the heuristics for the few fast judgments (backchannel, urgency,
did-they-finish, escalate). It runs beside the content path, never in front of
it, and must fail open. ~230–444 ms remote, ~tens of ms local logprobs.

## Turn-taking options (classic vs tyger)

Where the loop runs (above) is one axis; **how turns are decided** is another:
`classic` (today's endpointing / segmenter behavior — always available, the
fallback) vs `tyger` (the tyger decision model as the turn-taker). Selection,
fallback and rollout: `voice-tyger-option.md`.

## Rules of thumb

- Never put an LLM turn in front of another LLM turn for a passive call.
- Keep the greeted persona the agent's, not the transport's.
- The biggest lever after the architecture is the model: remote round trip vs
  on-device AFM3.
