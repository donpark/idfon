# Voice agent: a peer that speaks and listens for other agents

Status: **design agreed 2026-10-03; implementation in progress.** Companion to
`docs/voice-side-channel.md` (the engine seam + cascade decisions) and
`docs/live-voice.md` (the GPT-Live deployment of the same transport).

## What a voice agent is

A **voice agent** is an ordinary idfon **peer** — an endpoint id plus a
capability ticket — whose job is voice *I/O* for another agent. Audio is
carried as a **live MoQ session** (a real call), the same transport the
`live-voice` demo uses. The voice agent turns caller speech into text, hands
that text to an agent, takes the agent's reply, and turns it back into speech.

It is reached **by its endpoint id (+ ticket)**; that reference is the
`voice_route.delegate = { peer_id, ticket, audio }` field already carried on the
capability ticket, so a caller or an agent can discover and route to it without
a display-name heuristic.

The agent whose words are spoken never knows it was spoken to — it only sees
text.

## Two ways to use it

- **Wrapped** — the voice agent is a liaison *in front*. The caller talks to the
  voice agent; it relays the transcript to the **wrapped** agent over A2A (the
  same card/turn relay the `agency` already uses), takes the reply, and speaks
  it. The wrapped agent is configured on the voice agent (or introduced by card).
- **Injected** — the voice agent sits *behind* a target agent. The target keeps
  its own contact and uses the voice agent to listen/speak for it; the caller
  talks to the target.

Both are the same voice-agent peer. Only the text target differs.

## Where the transcript goes (the handler seam)

The voice agent's holder runs a cascade live-call handler:

```
caller app ── IDFON-LIVE/1 start (ticket) ──▶ voice agent holder
   handler: subscribe caller MoQ → STT → transcript
            │
            ├─ default: inject a turn into the voice agent's OWN Eve agent
            │           (that agent answers, or forwards to a wrapped agent)
            └─ target override: inject straight into a configured target
                                agent (endpoint + ticket) — pure relay
            │
            agent reply text (ReplyTarget.live_commentary)
            │
            TTS → publish return leg ──▶ caller app plays it
```

The handler stays generic; **wrapping is agent/tool logic**, not handler logic.
The optional target override covers the pure-relay case where the voice agent's
own agent adds nothing.

Transcripts ride out as `IDFON-CALL/1` snapshots and into the durable record
buffer (P0), exactly as the GPT-Live path does.

## Engine

The STT/TTS engine is the voice agent's private choice, behind the existing
`idfon-voice::VoiceEngine` seam:

- **On-device** (Apple, app process) — the default for a caller-side cascade;
  not reachable from a separate holder process.
- **Local model** (Kyutai STT + Kokoro TTS) — offline/private, the production
  target for a server-side voice agent.
- **Cloud** (`GatewayVoiceEngine`, AI Gateway) — the zero-install demo engine.

## The kit (fast iteration)

Adding a voice agent should not mean new Rust. The shared pieces live in two
crates and a backend is the only code an engine needs:

- `crates/idfon-live-media` — transport: caller subscribe, return-leg publish,
  invite parse/sign, pacing.
- `crates/idfon-voice-agent` — the kit: `VoiceBackend` trait, shared live loop,
  `TurnBridge` (inject turn + receive reply + record), config, and the single
  `eve-idfon-voice` runner. `--live-config` selects the backend
  (`backend` or `engine.kind`).
- Backends today: `cascade` (`CascadeFactory`, via `GatewayVoiceEngine`).
  GPT-Live and local engines implement the same trait; the runner registers
  each with one `with(..)` line.
- `agents/cascade-voice` — the demo voice agent; its `live.json` sets
  `backend` and `voice_route.mode = server-cascade`.

So: **add an engine** = one `VoiceBackend` impl + one registration; **add a
voice agent** = a config file (+ an Eve agent dir). No new handler, no new
binary.

## Routing modes

`voice_route.mode` tells a caller what the peer terminates:
`native-duplex` (full-duplex model), `server-cascade` (holder runs
STT→agent→TTS), `client-cascade` (caller supplies on-device STT/TTS), or
`delegated` (a separate voice agent speaks). The holder only intercepts a live
control when it advertises `native-duplex` or `server-cascade`.

## Not in scope here

- The injected (behind) deployment's service API (`speak`/`listen` calls from a
  target agent) — the `delegated` route recognizes it; wiring it follows.
- Local/on-device engines for the holder process.
