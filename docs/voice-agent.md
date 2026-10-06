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

### The caller chooses, per contact

The `voice` block is the holder's *advertisement*; the caller still chooses
which STT/TTS engines to run, per contact. The catalog is **not** in the signed
ticket — it is a resource the agent serves at path `idfon.json`
(`idfon://<holder>/idfon.json`), fetched on demand through the loopback
gateway (bounded at 3s) and cached by the app. So it stays fresh without
re-pairing and the ticket stays small.

- **`idfon.json`** — the agent's manifest. `voice.options` lists what it can
  run: `stt` / `tts` / `full-duplex` options, each with an `id`, a `label`, and
  a `side` (`server` = the holder runs it, `client` = the caller does).
- **Derivation + merge** — `eve_idfon::voice_options` derives defaults from the
  live config (one option per configured `engine` half, or a `full-duplex`
  option for a lone `model`) and merges the agent's manifest over them **by
  `id`**: the agent integrates (keeps a default) or overrides per option.
  `scripts/live-voice-serve.sh` folds `agents/<name>/idfon.json` into the live
  config as `idfon_manifest`.
- **Selection** — the contact detail has one **Speech** section with two
  pickers, **Recognition** (STT) and **Generation** (TTS). Each picker spans
  the app's on-device backends (`AsrBackend`/`TtsBackend`) and the agent's
  fetched `idfon.json` options; `ContactSpeech` reads/writes both stores behind
  one pick. The displayed value is the effective engine (the stored pick, else
  the app-global default — Apple Built-in for STT), never "Automatic". Catalog
  ids ride the `IDFON-LIVE/1` invite (`stt=<id>` / `tts=<id>`);
  `apply_voice_selection` resolves them on the holder into the cascade engine
  halves.
- **Full-duplex coupling** — a `full-duplex` option (e.g. GPT-Live-1) fills
  both halves: choosing it for either picker sets both, and pins
  `mode = native-duplex`.
- **On-device engines** — when a call runs the client cascade, the on-device
  pick is stored per contact (`ContactOnDeviceEngines`: Parakeet / Apple ASR,
  Kokoro / Apple TTS). Resolved at call start (`VoiceAgentSession`); absent =
  the app's global default (`SpeechEngines`). Choosing one clears the catalog
  pick for that half (and vice versa), so exactly one store owns each half.
- **Per-contact hybrid** — a live invite carries `stt_side=client` /
  `tts_side=client` when this device runs that half on-device (an on-device
  pick), so `apply_voice_selection` overrides the signed route's ownership for
  the call instead of the holder silently running both halves. The app runs it
  via `HybridVoice` (on-device ASR or TTS over the live session) using the same
  per-contact engine; `VoiceCallRouting.decide` resolves the route from the
  picks so a hybrid is actually detected. `VoiceRoute.resolving` is the shared
  Foundation-only resolver.
- **Codec** — the live-call audio codec is the holder's signed `voice.audio`
  (`pcm24k` → PCM, else Opus), not a manual per-contact choice. The media
  session, the dial decision, and the invite all derive it from the route, so
  the apps no longer expose an audio-profile picker.

The routing decision is pure (`VoiceCallRouting.decide`): a server/full-duplex
selection dials the holder's live session, an all-client selection is a client
cascade, and with no selection the signed route is followed. A stored holder
ticket with no `voice` block (an agent whose holder predates voice routing) is
treated as its documented default, `client-cascade` — on-device — never the
silent video-call fallback. Only a peer with no holder ticket at all (an
ordinary contact) keeps the name/PCM heuristic and the classic video call. The
`idfon.json` catalog fetch is bounded (3s) so a hung gateway cannot stall the
decision. Checked by `mac/Checks/VoiceCallRoutingCheck` +
`ios/Checks/VoiceCallRoutingCheck`. A call that cannot start posts a transient
chat status (`CallFeedback`: "No voice call available", "No live calls from
this contact", or "A call is already in progress") instead of failing
silently.

`scripts/live-voice-serve.sh` refuses to start when `EVE_LIVE_CONFIG` names a
missing file, so a holder cannot silently advertise no route.

### Introspection: ask the agent what it is

A caller can ask which model, STT, and TTS are running. The holder is the
authority: at startup it sends a vendor-neutral manifest
(`eve_idfon::voice_info`) over the bridge (`voice.info` → `/voice/info`),
derived from the live config plus `EVE_IDFON_MODEL` — `mode`, `backend`,
`voice_model`, `agent_model`, `voice`, `audio`, and the raw `engine` block
(unknown keys pass through, so a backend's own fields stay visible). Two
consumers use it:

- the Eve extension's `voice-pipeline` dynamic instruction injects it at turn
  start, so a cascade or text agent can answer;
- the GPT-Live backend appends it to the session `instructions`, so the
  full-duplex voice model can answer directly, without a delegation.

No vendor is baked into the platform: the manifest is generic metadata, and a
missing bridge/manifest simply means no introspection.

Beyond the holder's own manifest, the UI can push **per-turn caller context**
when it initiates a turn: an unsigned, bounded `context` field on
`message.send`. It rides the envelope (`MessageEnvelope.context`, like `trace`,
so older receivers ignore it) and the `voice-pipeline` dynamic instruction
injects it as an untrusted data block, flagged as the live state so it wins over
the static holder manifest. A client-cascade call uses it to report the
on-device engines it actually runs (e.g. "Recognition: Apple Built-in"), which
the holder cannot observe. Live calls carry the same string as `context_b64=`
on the `IDFON-LIVE/1` invite, folded into the holder's resolved per-call
pipeline (`voice_info`) for every injected transcript and the full-duplex
session instructions.

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

**Default (`agents/voice/live.json`)** is the streaming split — Deepgram
WebSocket STT (`nova-3`, `stream: true`) + ElevenLabs `/stream` TTS. Four
cascade behaviours are worth knowing:

- **One reply, one synthesis.** TTS is synthesized for the **whole**
  (envelope-stripped) reply when the turn completes, not per-delta: incremental
  synthesis raced the completed reply and truncated multi-clause answers after
  the first sentence. The provider still streams, so first-audio latency stays
  low.
- **Clauses in order.** A streaming provider's clauses go through one ordered
  worker; a task per clause interleaved their PCM and played the reply on top of
  itself.
- **Audio-only replies.** A voice-injected turn's reply is spoken to the live
  session only (`ReplyTarget.live_only`), never posted as a second chat bubble —
  the `IDFON-CALL/1` transcript is the single record.
- **Every reply is acked.** The holder must send a `reply.ack` for *every*
  reply, chat copy or not: the bridge's `/reply` blocks on it and returns 502
  otherwise, dropping the agent's reply before it reaches the live session.

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
benchmark. Each turn logs one structured `idfon.voice.metrics` event (STT ms,
TTS first/total ms, audio ms, estimated cost); `None` when a provider has no
price table rather than a made-up number.

### Try a provider (one command)

The generic voice agent plus a provider file is the whole flow:

```sh
scripts/voice-serve.sh agents/voice/providers/groq.json
scripts/voice-serve.sh agents/voice/providers/deepgram-elevenlabs.json
scripts/voice-serve.sh            # default live.json (AI Gateway env)
```

`agents/voice/providers/*.json` are full live configs (backend +
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
AGENCY_VOICE_DELEGATE_ALLOW_FILE="$HOME/.idfon/voice/allowed-peers" \
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
agent. The holder runs `backend = "relay"` (`agents/voice/relay.json`),
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
EVE_LIVE_CONFIG=agents/voice/relay.json scripts/voice-serve.sh
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
- `agents/voice` — the generic template (providers/relay/wrapping); its
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

## Hybrid STT/TTS ownership

A `server-cascade` voice agent does not have to own both halves. Its signed
`voice_route` can put one half on the caller:

```json
"voice_route": { "mode": "server-cascade", "audio": "pcm24k",
                 "stt": "client", "tts": "server" }
```

- `stt: "client"` — the caller runs STT on-device and sends each caller transcript
  to the holder as an `IDFON-LIVE/1 action=text text_b64=<base64>` control. The
  holder skips subscribing/STT and injects the text as the turn.
- `tts: "client"` — the holder skips synthesis and emits only the agent
  `IDFON-CALL/1` transcript; the caller speaks it with on-device TTS.

Both fields default to the mode's side (`server-cascade` → `server`), and the
holder advertises them in its capability ticket so the app routes accordingly
(`ios/Idfon/CapabilityTickets.swift`, `mac/Sources/Idfon/CapabilityTickets.swift`).
The app-side halves live in `HybridVoice` (`ios/Idfon/LiveCall.swift`,
`mac/Sources/Idfon/Calls.swift`): it dials the live session and either runs the
on-device ASR (sending text controls) or speaks the agent transcripts.

Ready-made configs: `agents/voice/providers/hybrid-stt-client.json` (caller
STT + holder ElevenLabs TTS) and `hybrid-tts-client.json` (holder Deepgram STT +
caller TTS). An in-process variant is also available: the `apple` provider
(`idfon-voice/apple_ffi`) selects the on-device engine where the app registered
`idfon_voice_set_bindings`, e.g. `{ "stt": { "provider": "apple" }, "tts": { … } }`.
