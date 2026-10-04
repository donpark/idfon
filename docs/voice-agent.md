# Voice agent: a peer that speaks and listens for other agents

Status: **implemented 2026-10-03** (unit/build-verified; live end-to-end and
the test suites are deferred). Companion to `docs/voice-side-channel.md` (the
engine seam + cascade decisions) and `docs/live-voice.md` (the GPT-Live
deployment of the same transport).

## What a voice agent is

A **voice agent** is an ordinary idfon **peer** — an endpoint id plus a
capability ticket — whose job is voice *I/O* for another agent. Audio is
carried as a **live MoQ session** (a real call), the same transport the
`gpt-live-1` demo uses. The voice agent turns caller speech into text, hands
that text to an agent, takes the agent's reply, and turns it back into speech.

It is reached **by its endpoint id (+ ticket)**; that reference is the
`voice_route.delegate = { peer_id, contact, ticket, audio }` field already
carried on the capability ticket, so a caller or an agent can discover and
route to it without a display-name heuristic.

The agent whose words are spoken never knows it was spoken to — it only sees
text.

## Baseline vs remote: who owns the audio

Voice I/O is an **app-side capability first**. Every 1:1 contact can be talked
to with no service in the loop:

- **app-side (baseline, free)** — the client app runs STT/TTS and exchanges
  text with the peer: a person over iroh, an agent via plain text turns
  (`client-cascade`), or on-device generation when there is no remote agent.
- **remote (opt-in, provider-pays)** — a voice agent as described here, or a
  `native-duplex` / `server-cascade` holder, terminates the audio.

Both are the same reference: the ticket's `voice` block (`mode`, `audio`,
`model`, `delegate`). The app reads `mode` and picks on-device I/O vs dialing
the capability. A remote capability is *chosen*, never required, so the free
tier never depends on one. An idfon-aware agent can also be handed the
reference (endpoint + ticket) and route its own voice I/O through it — the
injected case above.

## Agent-initiated calls (clarification)

The reference is an addressable capability, so the direction is not fixed: a
remote (sub)agent can **open** a session, not just answer one.

```
task delegated to a subagent
        | needs clarity
        v
subagent holds an injected voice reference
        |  <- voice capability
        v
opens a voice session with the user (or the originating agent)
        |  asks one focused question
        v
answer -> subagent continues
```

The user's app presents an agent-initiated call as an **incoming voice
request** (CallKit-style) they can accept or decline. Authorization is the
reference itself: the listening client issues the scoped voice grant
(`docs/voice-side-channel.md`, N9), so an agent cannot call a user it was not
handed a capability for. Two guards matter before shipping: a **rate cap**
(an agent must not spam a user with calls) and a **correlation id** on the
call — sessions are runtime, so a clarification call must name the task or
thread it belongs to rather than assume stored context.

## Two ways to use it

- **Wrapped** — the voice agent is a liaison *in front*. The caller talks to the
  voice agent; it relays the transcript to the **wrapped** agent over A2A (the
  same card/turn relay the `agency` already uses), takes the reply, and speaks
  it. The wrapped agent is configured on the voice agent (or introduced by card).
- **Injected** — the voice agent sits *behind* a target agent. The target keeps
  its own contact and uses the voice agent to listen/speak for it; the caller
  talks to the target.

Both are the same voice-agent peer. Only the text target differs.

## Where the transcript goes

Two handler styles terminate a live call, selected by `backend`:

- **`cascade` (Rust)** — the holder subscribes caller audio, runs STT, injects
each transcript as a turn into the voice agent's own Eve agent, and TTSes the
reply (`ReplyTarget.live_commentary`). The agent's tools decide what to do —
answer, or forward to a wrapped agent (`voice_forward`).
- **`relay` (TypeScript)** — the holder forwards caller frames to a standalone
Node relay (`live-relay.mjs`); that process owns STT/TTS and the wrapped-agent
hop, and posts audio back. See "Live calls in TypeScript".

Either way the handler stays generic; **wrapping is agent/relay logic**, not
handler logic. (A Rust-side "target override" that injects straight into
another agent is *not* implemented — wrapping happens above the holder.)

Transcripts ride out as `IDFON-CALL/1` snapshots and into the durable record
buffer (P0), exactly as the GPT-Live path does.

## Engine

`live.json`'s `backend` picks the call's audio shape, and the two shapes are
fundamentally different:

- **Full duplex** (`gpt-live`, `openai-realtime`) — audio in, audio out; the
  model owns turn-taking. There is no STT/TTS to configure.
- **Cascade** (`cascade`) — caller audio → STT → agent turn → TTS → return
  audio. The STT and TTS are **separate, independently selectable providers**,
  so trying a combination is config, not a new backend. On-device (Apple) is
  one such provider, not a third shape; placement (app vs holder) is orthogonal.

The STT/TTS side is the voice agent's private choice, behind the existing
`idfon-voice::VoiceEngine` seam:

- **On-device** (Apple, app process) — the default for a caller-side cascade;
  not reachable from a separate holder process.
- **Local model** (Kyutai STT + Kokoro TTS) — offline/private, the production
  target for a server-side voice agent.
- **Cloud** — any OpenAI-compatible audio API via `OpenAiCompatEngine`
  (`idfon-voice::gateway`), plus bespoke adapters for non-compatible vendors.

### Providers: lean on common APIs

Most vendors (and self-hosted servers) speak the OpenAI audio API
(`/audio/transcriptions` + `/audio/speech`), so a **profile** — base URL, key
env, model/voice ids — is all a new provider needs. The voice agent's `engine`
block selects it; no block falls back to the AI Gateway env:

```json
{
  "backend": "cascade",
  "engine": {
    "provider": "openai-compatible",
    "base_url": "https://api.groq.com/openai/v1",
    "api_key_env": "GROQ_API_KEY",
    "stt_model": "whisper-large-v3",
    "tts_model": "playai-tts",
    "voice": "Aaliyah-PlayAI"
  }
}
```

So supporting a new cloud ASR/TTS service is usually **config, not code**.
Providers that are only *almost* compatible are handled by a profile too;
genuinely bespoke APIs get a small adapter behind the same seam. Today:
`openai-compatible` (the long tail), `deepgram` (STT + TTS), `elevenlabs`
(TTS), and `cartesia` (TTS); mix any STT with any TTS via a split `stt`/`tts`
engine block. Streaming where it matters: ElevenLabs TTS streams by default
(chunked `/stream`, audio pushed as it synthesizes); Deepgram STT can stream
via `"stream": true` (WebSocket partials, lower first-final latency) while
batch REST stays the default.

Open-source / local providers:
- `kokoro` — Kokoro TTS (and ASR) via `kokoro-fastapi`, an OpenAI-compatible
  server on localhost, no key. `providers/kokoro.json`.
- `command` — shell out to any model CLI: `stt_cmd` reads the WAV at `{input}`
  and prints the transcript (or writes `{output}`); `tts_cmd` reads the text at
  `{text}` and writes a WAV to `{output}`. That covers Whisper, Parakeet TDT,
  Piper, Kokoro CLI, … — `providers/parakeet.json` is a template (adjust the
  command to your install).

idfon's value here is the **real-use harness**: add a contact per provider and
actually converse, then compare latency/cost/quality — not a synthetic
benchmark. Each turn logs one `[voice-metrics]` JSON line (STT ms, TTS
first/total ms, audio ms, estimated cost); `None` when a provider has no price
table rather than a made-up number.

### Try a provider (one command)

The generic voice agent plus a provider file is the whole flow:

```sh
scripts/voice-agent-serve.sh agents/voice-agent/providers/groq.json
scripts/voice-agent-serve.sh agents/voice-agent/providers/deepgram-elevenlabs.json
scripts/voice-agent-serve.sh            # default live.json (AI Gateway env)
```

`agents/voice-agent/providers/*.json` are full live configs (backend +
`voice_route` + `engine`); add one per service. Keys come from the env vars the
file names. `EVE_LIVE_CONFIG` overrides the agent's own `live.json`.

## TypeScript voice tools: `eve-idfon-voice`

Open-source models that bundle (WASM/ONNX/npm) run in the **agent's Node
process**, not the Rust holder — so a voice agent's STT/TTS are ordinary TS
calls. The shared toolkit lives in **`integrations/eve-idfon-voice`** (npm
`eve-idfon-voice`), the voice companion to `eve-idfon`:

- `providers` — `createVoiceProvider(config, "stt"|"tts")` with `command`
  (CLI), `openai-compatible` (cloud or a local server), `module` (dynamic
  import of a provider package), and `kokoro` (via `kokoro-js`). Selected by
  the `IDFON_VOICE_ENGINE` env (JSON), same shape as the Rust engine block.
- `audio` — Ogg Opus → s16le PCM, WAV wrap/parse.
- `turn` — `EnergyEndpointer`, `trimTrailingSilence`, `ClauseBatcher`,
  `stripEnvelopes`, `EchoSuppressor`, backchannel/barge-in helpers.
- `wrap` — the wrapped-agent target from config; `forwardToWrapped`.
- `bridge` — blob upload, an agent→agent `sendAwait`, and `playAudio` (push
  PCM to a live call's return leg).
- `tools` — tool factories so an agent's files are one line:
  - `voiceRelayTool()` — **wrapping** in one shot: voice memo → STT → text to
    the wrapped agent (A2A, awaits its reply) → TTS → audio blob +
    `IDFON-DATA/1` envelope. The caller hears the wrapped agent; the wrapped
    agent only sees text.
  - `voiceTranscribeTool()` + `voiceSpeakTool()` — **self-answering**: memo →
    text for the agent to reason over, then speak its reply.
  - `voiceForwardTool()` — forward the caller's text to the wrapped agent
    (for a live turn the cascade already transcribed).
  - `voicePlayTool()` — speak text on the active live call's return leg.

Optional/bundlable packages load through a runtime import the bundler can't
see (`optional.ts`), so an agent builds without every provider installed; a
missing package fails only when that path is used.

So the diverse configurations are **config + persona**: an agent's tool file is
`export default voiceRelayTool();`, and the provider comes from
`IDFON_VOICE_ENGINE`.

### Wrapping the Agency (worked example)

`scripts/agency-voice-serve.sh` runs a voice agent that wraps the Agency:

- mints an Agency-issued ticket for the voice agent's own endpoint and admits
  the voice agent on the Agency allow-list (and the Agency on the voice agent's
  list, so replies land);
- sets `IDFON_VOICE_ENGINE.wrap = {peer_id, endpoint_id, ticket}`, so
  `voice_forward`/`voice_relay` need no arguments;
- serves the agent as `server-cascade` (`eve-idfon-voice` holder). A live call
  is transcribed by the cascade, injected as text, forwarded to the Agency, and
  the Agency's reply is spoken; a voice memo uses `voice_relay`.

The caller pairs with this **voice agent**, not the Agency; the Agency stays
text-only and unchanged. Because wrapping is config, the same script (with a
`wrap` pointing elsewhere) voices any other agent.

#### Delegated call routing (text to the Agency, calls to the wrapper)

Pairing the caller with the voice agent makes *everything* go through the
wrapper. To keep text on the Agency and route only **calls** to the voice
agent, advertise a delegate on the Agency's ticket instead:

```json
"voice_route": { "mode": "delegated",
  "delegate": { "peer_id": "<voice-agent>", "contact": {…endpoint addr…}, "audio": "pcm24k" } }
```

The apps read this: a **call** dials `delegate.peer_id` (the voice agent);
**text** goes to the Agency. Start the Agency with the delegate so its minted
tickets carry the route:

```sh
AGENCY_VOICE_DELEGATE=<voice-agent-peer> \
AGENCY_VOICE_DELEGATE_CONTACT='<endpoint-addr JSON>' \
AGENCY_VOICE_DELEGATE_ALLOW_FILE="$HOME/.idfon/voice-agent/allowed-peers" \
  scripts/agency-serve.sh
```

Then re-mint the caller's Agency ticket. The apps auto-add the delegate from
the signed `contact` on first call, and, because `AGENCY_VOICE_DELEGATE_ALLOW_FILE`
is set, each caller the Agency mints a ticket for is **admitted on the voice
agent's allow-file** at the same time — so the call dials without a separate
pairing. `VoiceDelegate` gained `contact` for the address; the allow-file
admission keeps the credential simple (the delegate holder accepts the caller
by allow-list, not a per-caller ticket).

### Live calls in TypeScript (standalone relay)

A live call can be terminated in TypeScript without the agent being an Eve
agent. The holder runs `backend = "relay"` (`agents/voice-agent/relay.json`),
which:

- forwards each caller PCM frame to the bridge as `audio.frame`;
- the bridge fans those out over SSE at `GET /live/stream`;
- plays whatever the relay posts back to `POST /live/audio` (the
  `audio.append` IPC path) on the call's return leg.

`integrations/eve-idfon-voice/live-relay.mjs` is that relay: a plain Node
process that reads the SSE stream, end-points utterances, runs STT, forwards
the transcript to a wrapped agent (`/send await_reply`), TTSes the reply, and
posts the audio back. Config is `IDFON_VOICE_ENGINE` (`stt`/`tts` blocks as in
the provider seam, plus `wrap` for the wrapped agent).

```sh
# 1. voice agent with the relay backend (writes $home/bridge-url)
EVE_LIVE_CONFIG=agents/voice-agent/relay.json scripts/voice-agent-serve.sh
# 2. the relay, pointed at that bridge
IDFON_VOICE_ENGINE='{"stt":{"provider":"openai-compatible"},"tts":{"provider":"openai-compatible"},"wrap":{"peer_id":"…","endpoint_id":"…","ticket":{…}}}' \
  scripts/voice-live-relay.sh
```

`scripts/voice-live-relay.sh` reads the bridge URL from
`$home/bridge-url` (or `IDFON_BRIDGE_URL`).

This is the *channel-level live audio* path (B); the per-utterance attachment
path (A) is the simpler alternative that reuses the Eve tools.

## The kit (fast iteration)

Adding a voice agent should not mean new Rust. The shared pieces live in two
crates and a backend is the only code an engine needs:

- `crates/idfon-live-media` — transport: caller subscribe, return-leg publish,
  invite parse/sign, pacing.
- `crates/idfon-voice-agent` — the kit: `VoiceBackend` trait, shared live loop,
  `TurnBridge` (inject turn + receive reply + record), config, and the runner
  binary `eve-idfon-voice`. `--live-config` selects the backend
  (`backend` or `engine.kind`).
- Backends today: `cascade` (`CascadeFactory`, Rust STT/TTS via `idfon-voice`)
  and `relay` (`RelayFactory`, frames to a standalone TS agent). GPT-Live is a
  separate `LiveCallHandler` on the same shared transport (`idfon-live-media`),
  not a `VoiceBackend`.
- `agents/voice-agent` — the generic template (providers/relay/wrapping); its
  `live.json` sets `backend` and `voice_route.mode = server-cascade`.

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
