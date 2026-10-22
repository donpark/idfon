# Fast-track voice agents

Status: **design statement (2026-10-21)** — the class the path-C model work
(`docs/voice-tyger-ondevice.md`) exists to make cheap. Names the pattern that
`docs/voice-agent.md`, `docs/voice-agent-modes.md` and the tyger port each
describe a piece of.

## The name

**Fast-track.** The critical property of a voice conversation is latency —
every 100 ms at a turn boundary is felt as the agent talking over you or
lagging behind you — and on-device is king of low-latency. So the fast track is
the architecture where the voice substrate runs **where the audio is**: a
lightweight ASR, a TTS, and a tyger-class turn-decision model on the device.
Agents — **on-device or off-device** — ride above that substrate through a
text boundary. The fast track is the part of the path that can never afford a
network hop; everything else may use one.

## The class

The device converts:

| direction | conversion |
| --- | --- |
| in | voice → text **+ turn metadata** (endpoint, barge-in, backchannel, floor state) |
| out | text → voice (buffering, pacing, and cut-off handled by the runtime) |

The agent itself is a **text program** — it never touches audio. What it
implements is then only its **interaction heuristics** — when to speak, when to
yield, what to ask — the orchestration it was designed for. What it never sees:
waveforms, VAD, thresholds, endpoint debounce, synthesis timing.

Because the substrate is local, an **off-device agent gets local-grade turn
reactions too**: the endpoint that says "your turn ended" and the barge-in that
cuts the agent off fire on the device, at device latency, no matter where the
agent's thinking happens. Only content generation may be slow — and for a
remote agent it is slow anyway (it is the LLM round trip). This is what makes
fast-track the best support for both agent placements at once: the turn-taking
latency budget is constant, and only the content latency varies
(`docs/voice-agent-modes.md`'s axis).

This is a *class*, not the only architecture: remote ASR/TTS remain available
for affiliation (a hosted engine's voice identity, a language tier, an operator
relationship), and hybrid stacks (on-device turn-taking with hosted STT, or
on-device STT with hosted TTS) are valid members. The class is defined by the
**default substrate**, not by exclusivity.

## Why the device

- **Latency first**: no network in the turn-reaction path; endpoint and barge
  decisions are local, so turn-taking feels identical for local and remote
  agents.
- **One encoder pass per hop** feeds ASR transcription and the turn-decision
  heads alike (the path-C student reads Parakeet features) — no second model
  over the same audio.
- **The free tier** (`docs/voice-agent-modes.md`): an on-device turn costs only
  battery; every off-device turn costs money at three vendors.
- **Privacy**: the audio never leaves the device unless an affiliation is chosen.

## The contract

Inbound turn events are the tyger rules' output (`crates/idfon-voice`, the Rust
port of the rules): ENDPOINT / BARGE / BACKCHANNEL / FRAME + the state machine.
Outbound is plain text plus speak directives (`IDFON-SPEAK/1`) — exactly the
provider-neutral shape of `docs/voice-agent-loop-contract.md`, at its strongest
form: prompt plain, provider a tier detail, audio a runtime detail.

Engine selection stays per-contact and caller-chosen (`docs/voice-agent.md`'s
`idfon.json` selection), so affiliation and hybrid stacks are configuration,
not architecture changes.

## What makes it possible

The turn-decision model at device scale: the tyger decision path is 14M params
on features the ASR encoder already computes. Distilling it onto Parakeet
features (2026-10-21, student at teacher parity in use) collapses the delivery
cost to ~28–56 MB on top of the ASR/TTS the agent needs anyway — total
first-use download ~375 MB, uniform across device tiers.

## See also

- `docs/voice-agent.md` — the voice-agent carrier (text-only agents, app-side
  baseline vs remote opt-in)
- `docs/voice-agent-modes.md` — placement and cost per turn
- `docs/voice-tyger-ondevice.md` — the decision model's device tiers and port
- `docs/voice-agent-loop-contract.md` — the provider-neutral loop contract
