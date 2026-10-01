# Voice side-channel service

> **Status: design, P0–P1 implemented** (2026-10-01). The record-only coupling in
> "Writing to Eve history" (§P0 implementation) ships in `crates/eve-idfon`
> and the `eve-idfon` extension; the provider seam (§P1 implementation) ships
> as `crates/idfon-voice`. P2+ remain design. Follow-on to the decision in
> [`ai-voice-chat.md`](ai-voice-chat.md) ("Decision: fix the coupling before
> swapping transport or front-end"). Companion to
> [`audio-media.md`](audio-media.md) (capture/playback rules),
> [`idfon-eve.md`](idfon-eve.md) (channel model), and the research in
> `docs/archive/idfon-harness.md` / `docs/archive/omini-duplex-omni.md`.
>
> Revised twice after independent design reviews (2026-10-01). The second review
> blocked on Eve's history contract (B1), the signer rule under A1 (B2), and the
> false "1:1 only" scope claim (B3); all three are fixed below.

## Scope

This design is the **cascade voice side-channel**.

- **Voice memos, spoken answers, and live calls** all use the cascade
  (STT → agent → TTS). `ai-voice-chat`'s GPT-Live relay
  (`crates/eve-idfon/src/call.rs`,
  `agents/ai-voice-chat/agent/tools/voice-reply.ts`) is **demo scaffolding to be
  retired**; realtime live-call UX is delivered by streaming (F11), not by
  keeping GPT-Live. GPT-Live is **retired at P4 (iOS) / P5 (macOS)**; until then
  it is an **explicit F9 exception** (a speech-to-speech speaker would otherwise
  break the text boundary). It is a migration target, not a permanent fallback.
- **Voice is 1:1 only.** Rooms already exist (`chatrooms.md` R1-complete), so a
  room **by membership** (not merely a set `conversation` — threaded 1:1 also
  sets one) must not open a voice session. This is an **explicit exception** to
  `chatrooms.md`'s "1:1 equivalence, no room-only code path", and must be
  recorded there. **Enforcement lives in `handle_live_text`** (before the
  `IDFON-LIVE/1` dispatch in `main.rs`) and is **P0**, not P2. In the P0
  implementation the guard is the `message.conversation.is_none()` condition on
  that dispatch, so a room-addressed control falls through as ordinary content.
  Room-addressed turns and **room voice memos** are passed through **text-only**
  (not transcribed). Tested.
- **A single-agent focus** is therefore the callee. The "Alice, …" override and
  a cross-agent arbiter are deferred until voice-in-rooms is designed.

## Goal

One **voice side-channel service** that gives any idfon agent a voice without
that agent implementing one. An agent emits text and artifacts through the
existing message model; the voice service turns text into speech and turns user
speech into text. Audio is a capability of the channel, not a feature of each
agent.

The load-bearing constraint: **the service boundary is text.**

## Non-goals

- Not the conversational brain, not a context owner. The **canonical transcript
  is the actor's session record**, not the service's; the service only records
  into it (see "Writing to Eve history").
- Not a per-agent tool. The current `voice_reply` tool is the thing being
  replaced.
- Not committed to any single engine. STT, TTS, endpointing, and (later) a
  full-duplex engine are behind a provider seam.

## Requirements

### Functional

| ID | Requirement |
| --- | --- |
| F1 | **`speak(text, voice)`** — the output verb. Speaks text; `voice` selects from a registry; agents may omit for a default. |
| F2 | **Listen** — while a session is active, accept caller audio and publish **partial** (replaceable) and **final** transcripts. |
| F3 | **End-of-turn, one authoritative endpointer per topology** — client on-device endpointing *or* service semantic VAD, not both acting. The non-authoritative endpointer only feeds barge-in. |
| F4 | **Focus/addressing** — 1:1 only (voice in rooms is out of scope); each final turn routes to the callee's session. |
| F5 | **Arbitration** — one active speaker; agents queue; preemption is a policy. |
| F6 | **Barge-in** — user speech flushes in-flight playback locally; the follow-up is `steer` before playback, or `cancel` + `queue` after. Deltas are dropped by a barge-in counter (not `turnId`), a backchannel never cancels tool work, and what was heard is recorded (see "Barge-in semantics"). |
| F7 | **Events** — a user turn is a signed message whose chat bubble is its display projection; one event, two projections. |
| F8 | **Voice registry** — named voices with provenance and license; `speak(text, voice)` resolves against it. |
| F9 | **Non-substantive non-actor speech only** — any layer may speak or stay silent, but director/voice-service speech is limited to a **closed set of non-substantive kinds** (acknowledgement, status, system notice), templated or length-capped, with no facts. Every utterance is recorded in the canonical transcript labeled with its speaker. The actor can preempt it; it never overlaps actor speech. |
| F10 | **Action risk** — voice-originated turns carry `source=voice`, `confidence`, `alternatives?`, so approval policies can require confirmation for impactful tools. |
| F11 | **Streaming agent output** — the agent's reply reaches TTS as **deltas**, batched to clause boundaries (see "Streaming forwarding"). Envelope/artifact spans are excluded deterministically (no LLM). |

### Non-functional

| ID | Requirement |
| --- | --- |
| N1 | **Per-hop latency budget** — publish a budget table (end-of-turn → STT final → client sign → holder → Eve turn start → first `message.appended` → first audio) with p50/p95 per hop; ~500 ms–1 s end-to-end only if the budget closes. Measure Eve-overhead in P0/P1. |
| N2 | **Streaming both ways** — partial STT in; TTS fed incremental agent text (F11). |
| N3 | **Provider seam** — STT/TTS/endpointing interchangeable: local and cloud. Engine processes are **shared per host** behind the seam, not one per holder. |
| N4 | **License-clean** — permissive code and weights where the client is concerned; server-side copyleft handled by process separation (and GPL obligations still apply to shipped npm packages). |
| N5 | **Rust-first** on the service; Apple-native (Swift) on the client under A1; on-device MLX where memory allows. |
| N6 | **Privacy** — capture stays with the caller; raw device audio never crosses daemon IPC; **audio capture is opt-in and off by default**; retention defined (see "Retention"). |
| N7 | **Testable** — a no-network pipeline check plus a deterministic text path. |
| N8 | **Cost** — metered only while a session is active. |
| N9 | **Authorization** — `speak` requires a scoped `voice.speak` grant issued by the **listening client** (the speaker's target) and enforced at the holder/voice component; a holder of *other* grants cannot inject speech. The grant gates explicit `speak()`, zero-integration auto-speak, and non-actor speech, with rate and length caps. |
| N10 | **Observability** — one trace id from end-of-turn through agent → `speak` → first audio. |
| N11 | **Disclosure & degradation** — disclose any inference hop off the holder (including a remote CUDA `moshi-server`); STT down → text input, TTS down → text bubble, director down → deterministic fallback. |
| N12 | **Voice approvals** — a spoken "yes" becomes a structured `respond()` signed by the **client**; it is never inferred from service STT, director speech, or voice-service speech. Under A2 the client's only transcript is service STT, so A2 approvals are **tap-only** unless an on-device keyword recognizer is added; pending-approval keywords are exempt from echo suppression. |

## Architecture

Three layers, plus a policy director role.

```text
actor agent (content, tools)
   │  speak(text, voice)              ▲ addressed final turn
   ▼                                  │
┌────────────────────────────────────────────────────┐
│ voice service (channel edge)                       │
│  TTS │ arbiter/preemption │ STT │ registries       │
│  endpointing seam │ policy director (dirs)         │
└────────────────────────────────────────────────────┘
   │  speaker (MoQ)     ▲ caller audio (MoQ)  │ turn events
   ▼                    │                    ▼
┌────────────────────────────────────────────────────┐
│ client: voice-endpoint controller                  │
│  capture │ AEC │ barge-in flush │ endpointing      │
│  signs final turns as the user                     │
└────────────────────────────────────────────────────┘
   ▲ mic / ▼ speaker
```

Placement is logical, not physical: under A1 the policy director would run
client-side, not inside the voice service box (AFM director deferred — see
Policy director).

| Layer | Owns | Does not |
| --- | --- | --- |
| client voice-endpoint controller | capture, AEC, barge-in flush, endpointing; signs final turns as the user | content, routing policy |
| voice service | STT/TTS, one-speaker arbitration + preemption, model registry, endpointing seam | focus policy |
| policy director | focus/addressing, modality **defaults**, timing directives; may speak non-substantively (labeled) | authoring the actor's answer |
| actor agent | its own answer content, tool calls, final modality choice | routing |

Concern ownership (one owner each): **focus** → director; **modality default** →
director, overridable by the actor's `speak()`; **arbitration/preemption** →
voice service; **barge-in** → client.

Rules:

- Capture/playback and AEC are **always client-side** (`audio-media.md`; raw
  device audio never crosses daemon IPC).
- The client emits **turn events, not raw VAD fragments**. **Partial**
  transcripts are replaceable and never enter agent context; **final** turns are
  what agents act on.
- **Steering is UI + barge-in gating only.** `voice.transcript` subscribers
  receive finals; partials drive only the client surface.
- **Any layer may speak or stay silent**, but non-actor speech is restricted by
  F9. One canonical transcript records every utterance labeled by speaker.
- **Agent output streams (F11).** The service feeds TTS incrementally and keeps
  a **display-only** coalesced copy; Eve's `message.completed` is the
  authoritative history copy.

### Writing to Eve history

Eve adds to session history via `send()` (turn input, invokes the model),
`respond()` (answers a pending input/approval), user-role dynamic instructions
(land at a session/turn boundary — `execution-model-and-durability.mdx`), and
internally via recalled memory, tool results, and compaction summaries. It
provides **no provider-message queue** (`channels/overview.mdx`). Consequences:

- **P0 records; it does not trigger turns on caller/agent utterances.** They go
  into a **durable holder-side buffer** keyed by the 1:1 address and are
  surfaced by a **resolver shipped in the extension** (`extensions.md` supports
  dynamic instructions) as a **user-role dynamic instruction** — fetched over
  the bridge, drained **idempotently per `turnId`**. Instruction resolvers run
  only on `session.started`/`turn.started`, so a call summary is written at
  hangup and reaches the model at the **next** boundary (when the user
  returns). Records land before the current delivery, so ordering is preserved.
- **Two P0 `send()` exceptions, both explicit:**
  1. **cascade turns** — the client-signed user message is the turn input;
  2. **GPT-Live delegation** — `call.rs` turns `session.delegation.created` into
     a normal Eve turn today. It is tagged with provenance
     (`source=gpt-live-delegation`, a distinct auth attribute) so F10/approval
     policies treat it as non-user input; its turn boundary is where the record
     buffer drains mid-call; and **GPT-Live's spoken copy of the delegated
     reply is dropped** so the reply is not recorded twice.
- **`respond()` is for structured answers only**, never transcripts (N12).

### Signing and principal

In idfon the verified peer *is* the Eve principal; sessions and grants are keyed
on it (`idfon-eve.md`). Two separate rules:

- **Cascade user turns return to the client, which signs them as ordinary user
  messages** — same principal, session, grants, HITL. The service records
  `transcribed_by` provenance but never signs as the user.
- **Non-user speech is signed by whoever produced it.** The holder key signs
  holder-side director/voice-service speech; **client-side director speech is
  local-only and never reaches the wire** (the client holds no agent key). The
  speaker label is a **required signed field** that the UI must render, so no
  consumer sees agent-authored text the agent never wrote. In history, records
  are **structurally encoded** (escaped JSON with a fixed `speaker` enum), not
  free-text labels, so a caller cannot forge `[director]: …` inside a
  transcript. The **audit copy is the holder's append-only log**; Eve history is
  the model's view of it. **Under A1 non-actor speech is forbidden** until a
  client-signed `client-director` record type exists (A2 ships first).
- **Voice approvals (N12)** are always a client-signed structured `respond()`,
  never inferred from any speech.

The GPT-Live-era P0 transcript is a recording, not a user-signed turn: its
holder-side lines are labeled history, and the client-signing rule applies only
to the cascade.

### P0 implementation

- **Store** (`crates/eve-idfon/src/records.rs`): one JSON file per 1:1 peer
  address under `$IDFON_VOICE_RECORDS_DIR`, else `$EVE_VOICE_HOME/voice-records`
  (the serve script sets `EVE_VOICE_HOME=~/.idfon/ai-voice-chat`), else
  `$HOME/.idfon/eve-voice-records`. Append-only records with a fixed
  `kind`/`speaker` schema (`transcript` for caller/agent finals, `call_summary`
  at hangup); `drain` advances a cursor, so the buffer survives a holder
  restart. Per-peer records are capped (oldest trimmed, cursor advanced).
- **Fetch**: the resolver POSTs `{peer_id, turn_id}` to the loopback bridge
  `/records/drain`, which forwards `records.drain` over holder IPC. `drain` is
  **idempotent per `turnId`**: a replayed/resumed turn returns nothing.
- **Resolver**: `integrations/eve-idfon/extension/instructions/voice-records.ts`
  is a `defineDynamic` **user-role** instruction on `turn.started`; it emits the
  records as escaped JSON (`speaker` is a fixed enum, so a transcript cannot
  forge a label). No records → `null` (no history entry). A bridge failure
  returns `null` and leaves the records buffered.
- **Rooms**: a `conversation`-addressed live control is not intercepted
  (voice is 1:1) and falls through as text-only content.
- **Delegation provenance**: `IpcFrame::TurnIn` carries `source`; a live
  delegation sets `source=gpt-live-delegation`, which the channel exposes as the
  `idfon_source` auth attribute. GPT-Live's spoken readback of the delegated
  reply is matched (whitespace-normalized) and dropped before it is recorded or
  sent as a transcript bubble, so the reply is recorded once (in the Eve turn).
- **Eve overhead (N1)**: measured on the loopback drain path (debug holder +
  bridge, 21-record payload, 300 iterations): first (cold, loads file) 20 ms;
  warmed **p50 1.9 ms / p95 2.8 ms / max 4.0 ms**. The resolver logs
  `voice records drained count=… in …ms turn=…` so the live per-turn cost stays
  observable. This is well inside the N1 budget; the voice hops, not this
  resolver, dominate end-to-end.

### P1 implementation

- **Seam** (`crates/idfon-voice`, no engine deps): `VoiceEngine` is a stateless
  `Send + Sync` factory — one per host (N3) — that hands out boxed
  `SttSession` / `TtsSession` / `Endpointer`. `TtsSession` consumes agent text
  **deltas** and returns PCM batched at sentence boundaries (F11 groundwork);
  `SttSession` returns `Partial`/`Final` events; `Endpointer` reports
  `SpeechStarted`/`SpeechEnded`. `AudioFormat`/`PcmChunk`/WAV wrapping are
  provider-neutral.
- **Stub** (`StubVoiceEngine`): deterministic and offline — STT transcribes
  nothing, TTS emits silence whose length tracks the text, and the endpointer
  uses the same energy gate the call path already uses. For tests and the
  offline gate only; never a production default.
- **Offline gate**: `scripts/voice-pipeline-check.sh` runs
  `cargo run --offline -p idfon-voice --example pipeline` (text → PCM → WAV)
  and validates the WAV. No network, no credentials.

### Placement

Under A2, the voice component runs **at the channel edge (the per-agent
holder)**, as a shared crate instantiated per holder — the place that sees the
caller's audio and the agent's outbound replies. A separate shared process is a
later option, but then agents must route through it (opt-in), dropping
zero-integration. Under A1 the client sees both, and the director may be
client-side.

### Deployment topology

| | STT/TTS inference | Agent location | Latency | Privacy | Voice quality |
| --- | --- | --- | --- | --- | --- |
| **A1** app-local | on device (Apple-native) | on device or remote | lowest | audio never leaves device | OS voices; no cloning |
| **A2** remote voice agent | in the voice service | local (app) or remote, over iroh | + iroh hop + cascade | audio leaves the device (E2E via iroh) | model registry (Kokoro/Kyutai) |
| **A3** both | either | anywhere | per deployment | per deployment | both families |

A1/A2/A3 are **topology, not addressing**. **Recommendation: target A3, ship A2
first.** The provider seam must cover two families: **Apple-native**
(SpeechAnalyzer/VAD/AVSpeechSynthesizer) and **model-based** (Kokoro/Kyutai).
Under A1 the OS voices satisfy the offline default, making Tier-0 Kokoro
optional.

### Echo cancellation (corrected)

- **iOS already has AEC** for calls: `LiveCall` uses `.playAndRecord` +
  `.voiceChat` (VoiceProcessingIO) (`ios/Idfon/LiveCall.swift`,
  `ios/Idfon/AudioPusher.swift`; `troubleshooting.md`).
- **macOS has none** — `troubleshooting.md:45` notes it is deliberately left
  without VPIO; `audio-media.md` states there is no echo cancellation.
- **AEC is a P5 concern.** Full barge-in where AEC exists (iOS); **gated or
  threshold barge-in on macOS** (no AEC). AEC alone is insufficient (residual
  echo self-triggers), so:
  - **Half-duplex is a fallback, not the default**: gate STT/barge-in during
    playback only where AEC is absent.
  - **Text-layer echo suppression**: drop finals that fuzzy-match the text
    currently being spoken.
  - Make **macOS AEC** the real work item. P4 streaming cannot be called the
    live-call gate on macOS before P5.

### Barge-in semantics

Two cases, because `steer` keeps the **same** `turnId`:

- **Before any delta or playback:** `steer` only; drop nothing, do not cancel.
- **After playback has started:** flush locally, `cancel({turnId})`, wait for
  `turn.cancelled` (`idfon.ts` forwards it), then `send` with the default
  `queue`. Key the delta drop on a **barge-in counter**, not `turnId`, so the
  steered follow-up is not discarded.
- **Do not cancel tool work.** Cancel only while playback is active **and** the
  utterance passes a backchannel / minimum-length filter; never cancel during
  `actions.requested → action.result` — queue instead. An "uh-huh" must not
  kill a running tool.
- **Record what was heard.** Eve discards incomplete assistant output on cancel,
  so `playback.truncated{msg_id, heard_until}` is buffered via the recording
  mechanism.
- **Retries and failures:** a provider retry repeats the same
  `turnId`/`stepIndex`/`sequence`; **dedupe spoken text by that triple** and
  speak at **sentence** boundaries only (one granularity, not clause *and*
  sentence). Record a "heard" entry whenever spoken text differs from
  `message.completed`. Treat `step.failed` (or repeated coordinates) as a
  stop-and-notice event; a content-filter failure leaves deltas with no
  `message.completed`.
- **Tests:** retry duplication, cancel/truncation, tool-cancel guard.

### Attach model (how an agent gains voice)

- Any agent publishes text turns through the existing message model, unchanged.
- The holder-edge **voice component** captures user speech → STT → returns a
  client-signed user turn, and renders the agent's outbound replies → TTS.
- **Speech selection is hybrid:** default to speaking plain text replies, treat
  envelopes/artifacts as present-only, and let an explicit `speak()` override.
- **Voice hint:** channel metadata or a dynamic instruction tells the agent the
  user is on a voice call, so replies are speakable — without breaking
  zero-integration.
- Guardrails: `speak` requires `voice.speak` (N9); the component holds no
  canonical state of its own; cloned voices are bound to their speaker with
  consent provenance and attribution.

### Policy director

**Use a deterministic director from P3 through P5**; defer the LLM/AFM director
until **voice-in-rooms is designed** (rooms already exist). The deterministic
director implements focus (= callee), modality default, and timing, and has no
generation.

- **Closed control-directive set**, no free-text fields: `route(turn_id →
  session)`, `set_focus(session)`, `present(msg_id)`, `suppress(msg_id)`,
  `preempt(utterance_id)`, `defer(msg_id, until)`. Directives control; they are
  not speech.
- **Speech is not a directive** and is restricted by F9; non-actor speech is
  enabled only once the P5 arbiter exists.
- **Precedence:** `suppress`/`defer` cannot override an explicit `speak()`
  (F9's actor-wins rule).
- **Validation:** reject directives whose references don't resolve, and check
  that a `route` target belongs to the same principal.
- **Append-only directive log**, auditable.
- **Deadline** is part of the N1 budget; a missed deadline uses the
  deterministic fallback (route to focus, speak the actor's text).
- **Projection size bound:** N events / K tokens.

**Authority vs. visibility.** The director inevitably holds conversation
history, so visibility is not the distinction. There is one **canonical
transcript** (the actor's session record), every utterance labeled with its
speaker; the director reads a bounded projection. It does not author the actor's
answer.

**On-device director engine (Apple Foundation Models)** — deferred until the
director is an LLM. When it is: on-device model, `@Generable` typed output, tool
calling, sessions/profiles, gated on Apple Intelligence hardware; treat
**Private Cloud Compute as unverified**; the engine is a provider seam with a
deterministic fallback.

## Candidate libraries

Verified 2026-10-01 against upstream docs/repos; re-check licenses at adoption.
"verify" = not confirmed from the source page.

### STT

| Candidate | Streaming | End-of-turn | Rust | On-device | Code license | Weights |
| --- | --- | --- | --- | --- | --- | --- |
| **Kyutai STT** `stt-1b-en_fr` | yes (0.5 s delay) | **semantic VAD** | yes (`moshi-server`, WS) | MLX (iPhone 16 Pro verified) | MIT (Py) / Apache (Rust) | CC-BY-4.0 |
| Kyutai STT `stt-2.6b-en` | yes (2.5 s) | no | yes | MLX | MIT / Apache | CC-BY-4.0 |
| Whisper (whisper.cpp / faster-whisper) | no (chunk hack) | separate VAD | bindings | yes | MIT | MIT |
| sherpa-onnx streaming Zipformer/Paraformer | yes | separate VAD | yes (C API) | yes | Apache-2.0 | varies (verify) |
| Vosk | yes | separate VAD | bindings | yes | Apache-2.0 | Apache-2.0 |
| Moonshine | near-stream | no | no (verify) | yes | MIT | MIT |
| Cloud: Deepgram / AssemblyAI / Speechmatics / ElevenLabs Scribe | yes | usually | HTTP/WS | no | proprietary | — |

### TTS

| Candidate | Streaming | Voice cloning | Multi-voice | On-device | License |
| --- | --- | --- | --- | --- | --- |
| **Kokoro-82M** | chunked | no | yes (54 voices, 8 langs) | ONNX int8/fp16; CoreML | **Apache-2.0** |
| **Kokoro-7M-Distill** (`oddadmix`) | chunked | no | **no — single voice (EN)** | 28.7 MB fp32, 45× RT on 4 CPU threads | Apache-2.0 |
| **Kyutai Pocket TTS** (100M) | yes (~200 ms first chunk) | yes | yes | CPU, ~6× RT on M4; browser (ONNX) | Python pkg (verify) |
| **Kyutai TTS 1.6B** | yes (delayed streams) | partial | yes | MLX; Rust server | code MIT/Apache |
| Piper | chunked | no | many | yes | **GPL** (`OHF-Voice/piper1-gpl`) |
| XTTS v2 (Coqui) | no | yes | few | GPU | **CPML, non-commercial** |
| Chatterbox / Orpheus / CSM | varies | some | some | GPU | usually MIT/Apache (verify) |
| Cloud: ElevenLabs / Cartesia / OpenAI / Deepgram Aura | yes | yes (some) | yes | no | proprietary |

Caveats: `sherpa-onnx`'s Kokoro/VITS path likely phonemizes through `espeak-ng`
(GPL) — verify. The **7M distill is a single-author community model**: listening
test before using as the default voice.

## Recommendation

**STT: Kyutai STT `stt-1b-en_fr`** (streaming + semantic VAD + Rust + MLX).
Note it is **EN/FR only**.

**TTS: Kokoro first; Pocket TTS when cloning/multilingual/streaming matters.**

- **Kokoro-82M** — Apache-2.0, 24 kHz, 54 voices / 8 langs, no cloning. ONNX
  int8/fp16 or CoreML for Apple.
- **Kokoro-7M-Distill** — 7.48M / 28.7 MB, 45× RT on 4 CPU threads,
  English-only, single voice (`af_msa`): a default voice, not a multi-voice
  backend.

**Front end:** Kokoro's G2P is **Python** (`KPipeline`/misaki, `num2words`). Tier
0 on a client needs a **native G2P port**, and `num2words` is **LGPL** — either
pre-normalize numbers or get legal review. Offline only matters under A1.
English can run espeak-free (OOD words skipped); ES/FR/HI/IT/PT use
`espeak-ng` (GPL-3.0) directly — separate server process, with GPL obligations
met when shipped in npm packages.

**Deployment tiers:** bundle the 7M default on-device (after the G2P port);
download better models with a manifest carrying size, hashes, and licenses. The
provider seam needs a small **model registry**; `speak(text, voice)` resolves to
an `(engine, model, voice-id)`.

**Mimi / waterlogging (corrected).** `kyutai/tts-1.6b-en_fr` tokenizes by
**Mimi**, 12.5 Hz, up to 32 tokens/frame; `config-tts.toml` uses `n_q = 24`.
Moshi uses Mimi at **8 codebooks** (~1.1 kbps) — the waterlogged setting. Same
codec family at exactly 3× the codebooks; fidelity is **empirical** (listening
test), and **BWE stays deferred**. Pocket TTS's codec is unverified.

`kyutai-labs/unmute` is the reference cascade; its full stack needs CUDA
Linux/x86_64, so Apple-first uses MLX or Pocket TTS on CPU.

## Phasing

Tracked on GitHub: epic **#17**, phases **#18–#25** (`donpark/idfon`).

- **P0 — couple first, record-only.** **Implemented** (2026-10-01): durable
  holder-side record buffer, idempotent bridge drain, `eve-idfon` dynamic
  user-role instruction resolver, `gpt-live-delegation` provenance, and the
  dropped spoken readback; Eve overhead measured (§P0 implementation). This is
  decision #1.
- **P1 — provider seam.** **Implemented** (2026-10-01): `crates/idfon-voice`
  defines `VoiceEngine` (STT + TTS + endpointing sessions) with a
  deterministic `StubVoiceEngine`; `scripts/voice-pipeline-check.sh` runs the
  text → PCM → WAV gate offline (§P1 implementation).
- **P2 — listen.** STT + one authoritative endpointer per topology; partial and
  final events; **room-addressed sessions rejected** (voice is 1:1).
- **P3 — speak (turn-level)** with a **deterministic director** (focus = callee,
  modality default). TTS + registry + `voice.speak` grant.
- **P4 — realtime streaming.** Agent reply deltas → incremental TTS (F11);
  deterministic envelope/artifact stripping; bridge batching; barge-in
  cancel/steer + drop-cancelled; `playback.truncated` recorded.
- **P5 — turn-taking & echo.** One-speaker arbiter (enables non-actor speech),
  full barge-in on iOS, gated/threshold barge-in on macOS, macOS AEC.
- **P6 — on-device.** MLX STT/TTS on Mac, then iOS where memory allows.
- **P7 — optional engines.** A deterministic-hosted or full-duplex engine used
  only as STT/TTS, or a new decision; BWE only if the P3 listening test demands
  it. LLM/AFM director deferred until voice-in-rooms is designed.

## Streaming forwarding

- Reach the holder over the **loopback HTTP bridge** (one POST per payload), not
  the side-channel ALPN.
- **Batch deltas to clause boundaries** before posting; add an explicit
  per-delta sequence number — Eve's `sequence` is a block coordinate, and
  ordering is stream order only.
- Keep a **display-only** coalesced copy; Eve's `message.completed` is
  authoritative history.
- Never speak `reasoning.appended`.

## Retention

- **Audio capture is opt-in and off by default.** The holder currently writes
  caller/agent WAVs to the temp dir on every call (`call.rs` `CallDiagnostics`),
  and the **client writes call audio too** (`audio-media.md`: `received.wav`,
  and the subscribed-call WAV keeps running). The opt-in default and the
  "no audio persisted" test must cover **both holder and client**.
- Define retention for: captured audio, transcripts, and the directive log
  (duration, location, deletion).
- N11 disclosure covers every inference hop off the holder, including a remote
  `moshi-server`.

## Test plan

- **No-network pipeline check**: text → PCM → WAV; stub engine for the
  deterministic gate.
- **Latency**: per-hop budget, including a streaming first-sentence → first-audio
  measurement.
- **Verbatim**: numbers/IDs/URLs, comparing **normalized** text or a WER
  threshold.
- **Self-echo**: half-duplex gating and text-layer suppression.
- **Barge-in**: cancel/steer, `playback.truncated` recorded, retry duplication.
- **Rooms**: a `conversation`-addressed turn is rejected for voice and degrades
  to text.
- **Authorization**: `speak` without `voice.speak` denied; rate/length caps.
- **Privacy**: a default call persists no audio on **holder or client**.
- **Director**: deterministic fallback on deadline; label rendering.
- **Approvals**: a spoken "yes" is a client-signed `respond()`.
- **License audit**: code and weights for every model and voice.

## Resolved

- **Streaming deltas (F11) — answer, do not re-scope as an Eve problem.**
  `eve@0.68.0` emits `MessageAppendedStreamEvent` (`type: "message.appended"`,
  fields `messageDelta`/`sequence`/`stepIndex`/`turnId`), plus
  `message.completed` per assistant step and `reasoning.appended` separately.
  Custom channels consume these via an `events` handler or a `WS()` route using
  `attachSession(id).getEventStream()` (NDJSON). The idfon channel coalesces per
  turn *by choice*; the work is idfon-side forwarding over the HTTP bridge.

## Open questions

- Confirm Kyutai TTS/Pocket TTS **weight** licenses and per-voice licenses.
- **Pocket TTS codec** (Mimi? which `n_q`?) — decide whether it beats Kokoro.
- `moshi-server` GPU need vs. Apple-first targets: local MLX/CPU vs. remote CUDA.
- Rust integration for Pocket TTS: Python vs. ONNX vs. sidecar.
- Native G2P port for Kokoro Tier 0; whether `num2words` (LGPL) can be dropped.
- **Languages**: STT is EN/FR and the 7M default voice is EN-only; define
  non-covered-language behavior.
- **Listening test** (P7 depends on it) and its pass bar.
- Design for voice-in-rooms (focus override, cross-agent arbiter).

## References

- Kyutai STT — <https://kyutai.org/stt>
- Kyutai TTS — <https://kyutai.org/tts>
- Kyutai STT/TTS models + Rust server — <https://github.com/kyutai-labs/delayed-streams-modeling>
- Kyutai TTS 1.6B model card (Mimi, 32 tokens/frame) — <https://huggingface.co/kyutai/tts-1.6b-en_fr>
- Pocket TTS — <https://github.com/kyutai-labs/pocket-tts>
- Unmute reference cascade — <https://github.com/kyutai-labs/unmute>
- Moshi / Mimi (8 codebooks) — <https://github.com/kyutai-labs/moshi>
- Kokoro-82M — <https://github.com/hexgrad/kokoro> · <https://huggingface.co/hexgrad/Kokoro-82M>
- Kokoro-7M-Distill — <https://huggingface.co/oddadmix/Kokoro-7M-Distill>
- Whisper — <https://github.com/ggml-org/whisper.cpp>
- Eve channel contract (history, streaming, turnPolicy) — `agents/ai-voice-chat/node_modules/eve/docs`
