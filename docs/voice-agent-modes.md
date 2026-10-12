# Voice agent modes

How a caller talks to an agent, and where the latency goes. Measured on
iPhone 16 / iOS 27.0.1 (`docs/voice-agent-harness.md` §5).

## The three modes

| Mode | Path | Latency per turn | When |
| --- | --- | --- | --- |
| **On-device agent** | STT → AFM3 loop (on-device) → TTS | ~1.5 s warm, **no network** | Private, offline, low-latency chat. Battery cost. |
| **Passive remote** | STT → wrapped agent (LLM) → TTS | remote round trip (~1.5–3 s) | The wrapped agent's knowledge/tools matter |
| **Proxy** | STT → AFM decides → wrapped agent → TTS | on-device turn **+** remote round trip (~3–5 s) | Per contact, when the voice layer has its own agency |

**Default is passive remote.** The holder (`live-voice-agent`) injects the live
config's `instructions` into the turn, so a plain text agent answers as a voice
agent without editing its own prompt. No LLM sits in front of the content.

**Proxy is opt-in, per contact.** It exists for modes where the voice layer
does something with the turn (intermediary, judge, interpreter) or has its own
tools. For passive conversation it only adds latency and failure modes (it
re-paraphrased a question, and its greeting echoed into the transcript). Set it
in the contact's detail screen ("Voice turns › Mode"); `-directorcall` forces a
proxy call on any contact, as the device probe for this path.

**On-device is opt-in** (`-directorondevice`). The AFM3 loop answers directly,
so there is no network. AFM3 has no tools and no live data; it chats and knows
what it was trained on. Use it for a private/offline assistant, not for a
knowledge agent.

## On-device agents are app-local contacts

The built-in **AFM 3** is seeded when the OS ships that model (**iOS/macOS
27+**). Users add more on-device agents as ordinary contacts, each a **name
plus a prompt** (`instructions`) — used like `llm` agent instances: the same
local model, a different role per contact. No daemon peer, no network. Stored
locally (`ios/Idfon/OnDeviceAgents.swift`, the mac twin under
`mac/Sources/Idfon/`); text and voice both run through `OnDeviceAgentRunner`.
AFM 3 cannot be deleted. Both shells merge them into the contact list and
title their threads and calls by name (`LiveActivityController`).

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

## Rules of thumb

- Never put an LLM turn in front of another LLM turn for a passive call.
- Keep the greeted persona the agent's, not the transport's.
- The biggest lever after the architecture is the model: remote round trip vs
  on-device AFM3.
