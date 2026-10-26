# Tyger streaming-pair transition plan

> Status: **plan** (2026-10-22, session-close deliverable). Goal: the full-streaming
> ASR + TTS stack Tyger's turn model was calibrated on, replacing the current
> whole-clip/batch pairing. After this: stereo calls (higher priority than
> agent voice quality).
>
> **2026-10-25: the new voice-agent ruling below names the three engines and
> the portability rule (the off-device agent is next).**

## The new voice agent (2026-10-25 ruling)

**User ruling**: the refactored on-device voice agent is fully duplex:
**Nemotron streaming ASR** for input (what Tyger uses — chosen to reduce risk
at this stage), the **on-device Tyger model** for input features and turn
management (ENDPOINT / BARGE / BACKCHANNEL), and **Gradium Phonon streaming
TTS** for output. The turn model needs the streaming mouth to utter voice
feedback (a "mm-hm") and to cancel fast on barge-in. Name note: "Phonon"
collides across two families — the mouth is Gradium's phonon-31m/40m
(`xn-ptts`); FermionResearch's Phonon-2/2.5 is a speech *recognizer* and is
not in this stack.

**Portability (user, 2026-10-25)**: the off-device voice agent is the next
project once the on-device one fully works. As the on-device architecture
solidifies it stays tier-neutral: decisions and the event vocabulary live in
`crates/idfon-voice` (the portable contract of
`docs/voice-agent-loop-contract.md` — prompt, tool schemas, trace record), the
apps hold only adapters (ASR/TTS engines, the Tyger feature encoders, the LLM
tier), and the off-device agent reuses the same core over the relay.

**Streaming contract (user, 2026-10-25)**: the engine seams keep supporting
other ASR/TTS engines — cloud services included — but a voice agent (on-device
or off) only runs an all-streaming pipeline: **non-streaming ASR or TTS
engines cannot be used in the agent path** (they stay usable for non-agent
features, e.g. text-only speak and batch export). **Voice-enabled LLMs are
first-class agents** (GPT-Live-1 class — already in the tree as the
`gpt-live-1` contact), and so is any voice-enabled agent's own engine choice:
as long as every component streams.

Build order (each step stays fail-open to today's behavior):

1. **Streaming mouth + feedback/barge** — done (2026-10-25): BACKCHANNEL
   speaks through the streaming mouth (never in history, never in the second
   ear — `FeedbackEar`; BARGE already cancels playback). Phonon streams on
   every path now (iOS text-only streams through a local player); the one
   utterance-per-call API speaks chunk-per-chunk once reply deltas land.
2. **Nemotron streaming ASR** behind the `AsrEngine` seam (FluidAudio
   `StreamingNemotronAsrManager`: append/process/partial callbacks), swapping
   Parakeet Redux as the call ASR.
3. **Tyger authoritative**: ENDPOINT (live under `TurnTakerSetting`) becomes
   the turn boundary per the swap-over convention; `onset_s` history trim on
   BARGE.
4. **Reply deltas → chunked speak** (Phase 1's text-streaming seam): chunk
   the LLM token stream at sentence ends (the `first_chunk` rule) into one
   `speak` per chunk (Tyger's mouth pattern).
5. Verification per Phase 4.

### Reply deltas — the remaining half (mapped 2026-10-25)

The mouth side is done: `SpeechChunker` (the `mouth/chunker.py` port) +
chunked speak, locked by `mac/Checks/SpeechChunkerCheck`. The delta wire's
server half already exists — the gap is delivery to the client-cascade app:

- `extension/channels/idfon.ts` `message.appended` → POST `/stream/append`
  (per-delta, retry-safe keys `(turn_id, step_index, sequence)`).
- `bridge.mjs` `/stream/append` → IPC `StreamAppend` (`crates/eve-idfon`).
- Holder `IpcFrame::StreamAppend` handler (`crates/eve-idfon/src/lib.rs`
  ~1046) → `deltas::route(peer, …)` → a registered `StreamingSpeaker`
  (`crates/idfon-voice/src/stream.rs`: ClauseBatcher + EnvelopeStripper +
  DeltaKey dedupe). **No subscriber ⇒ deltas are dropped — exactly today's
  client-cascade behavior.**

To close it (the app owns the TTS in the client cascade):

1. **Delivery**: the holder forwards deltas to the calling app — the call's
   live-session data frames (preferred: no message-log pollution) or
   correlated `speak` messages with a `final?: boolean` (default true =
   backward compatible) on `IDFON-SPEAK/1`.
2. **App**: the turn loop feeds `SpeechChunker.nextChunk` incrementally from
   the delta stream and speaks each closing chunk (the chunk loop seam
   already exists); the final message still carries display + correlation +
   the barge trim.
3. **Bubble**: one reply bubble upserted per delta (the existing
   `recordSpokenTurn(replacing:)`/`updateMessage` path).

Acceptance: first audio ≤ first sentence (~1–2 s) on a slow LLM; the
final-message bookkeeping (correlation, echo, barge trim) unchanged; the
corpus replay unchanged.

#### Reference wire (distilled 2026-10-26): HF speech-to-speech / ConvFill

Probed `smolagents/hf-realtime-voice` and `smolagents/convfill-speech-demo`
(client sources `main.js` + `s2s-realtime-client.js`; both run the official
`@openai/agents` RealtimeSession). Their wire:

- **One socket, two frame kinds.** OpenAI Realtime **GA** over WebSocket (or
  WebRTC): binary frames are 24 kHz PCM audio, text frames are JSON events —
  `input_audio_buffer.speech_started`/`speech_stopped` (server VAD,
  `turnDetection: {type: "server_vad", interruptResponse: true}`),
  `response.created` → `response.output_audio.delta` (binary) +
  `response.output_audio_transcript.delta` → `.done` → `response.done`, and
  `conversation.item.truncate` for the barge trim (the played-prefix event —
  the wire form of our `add_barged`). Both transcripts stream as deltas on the
  same socket; there is no message log in the loop.
- **Same mouth and rate as ours**: the ConvFill deploy synthesizes with
  Phonon 31M at 24 kHz (our pcm24k profile).

Consequence for the delivery choice: the reference shape is the live-session
delta stream (option A) in this vocabulary — delta events per chunk closed by
one `response.done`, with the final chat message unchanged for display and
history. Option B (message-log deltas) has no counterpart there and would be
our own invention. The call-assistant use-case (private coaching to the
user's earpiece; assistant voice injected into the outgoing stream) is the
same socket with more frame kinds — another reason to keep the loop on the
live session.

**What the ConvFill model does with the pipe** (paper: "Thinking While
Speaking", arXiv 2511.07397): *conversational infill* — after the user's
speech is transcribed, a 0.6B local talker speaks immediately to buy time,
then seamlessly weaves in the answer a 31B reasoner produced in parallel
(the talker is finetuned to merge delayed "cheat notes" into its stream).
That is our filler economy + reply deltas unified: the fast opening is not
throwaway filler but the beginning of the reply, continued from the
reasoner's stream. Our tier-neutral shape maps 1:1 — the local tier is the
talker, the remote agent is the reasoner, and the pipe above carries both.
Follow-up candidate, not part of this decision.

## Why (the evidence from 2026-10-22)

Tyger's model (`nineninesix/tyger`, per docs/voice-tyger.md) is calibrated on a
**causal, streaming loop on both ends**:

- Input: two aligned mono 16 kHz streams — caller's mic **and the agent's
  playback**; Nemotron L15 features (1,024 dims), 1 frame / 80 ms, no lookahead;
  320 ms decision hops; the app's LISTEN/SPEAK state fed as model state.
- Their mouth (`app/plugins/tts/voxcpm2.py`): streaming TTS, **one request per
  text chunk** (the LLM token stream is chunked with a `sentence` first-chunk
  rule), audio yielded per decode step.

Our A/B run 1 (`-tygerab kokoro|phonon`, scripted user audio + fixed reply,
real two-channel `TurnShadow`, `ParakeetStudentTurnModel` tier): the first
decision was **identical** across engines (user-channel-driven) while the later
decisions **diverged exactly in the window where the second ears differ**
(backchannel cadence: 3 events under whole-clip Kokoro vs 2 under streaming
Phonon). Timing gap confirmed huge: Kokoro `wav … in 780ms` (whole clip) vs
Phonon `first audio 6ms`. n=1, supportive — run 2 (fixed reply-start, N=3 per
engine) is the pre/post comparison tool.

Verdicts that shape the plan: BWE **dropped** (listening test: "differences but
can't say one is better"); VoxCPM2 **not a candidate** (slower than real-time;
its 48 kHz output is a calibration note, not a requirement); Pocket TTS
cloning-optional only.

## The three streaming legs

| Leg | Today | Target |
| --- | --- | --- |
| 1. ASR + features | Parakeet Redux (batch/re-encode) + path-C student heads on Parakeet features (~49% parity, shadow/fail-open, CPU/BNNS encode = the hangup watchdog root cause) | Nemotron **Speech Streaming** encoder, incremental (cache-aware, ~1× RT), L15 tap feeding the heads natively |
| 2. Agent text → TTS | `speak(fullText)` after the reply arrives complete | chunked speak (sentence first-chunk rule) over the LLM token stream, as the agent generates |
| 3. TTS → playback | **DONE**: Phonon streaming-through-the-bus (5–6 ms first audio, chunk-cancel barge, custom voices 256KB; `IDFON_TTS_PHONON=1`) | keep; Phonon is the tyger-mode mouth |

## Phases

### Phase 1 — text-streaming seam (small, independent of ASR)

- Chunk the agent reply stream at sentence boundaries (their `first_chunk`
  rule) and speak chunks as they arrive via Phonon's stream path.
- Needs: the holder/live-relay reply to arrive as deltas (verify — today's
  `reply_ms` timing suggests whole-reply), and `TtsEngine` a chunked speak
  (or one `speak` per chunk over the bus, already supported).
- Gate: endpoint→first-audio measured in `live-relay` turn-timing logs.

### Phase 2 — streaming ASR + feature tap (the big one)

**Decision (user, 2026-10-22): candidate A** (Nemotron Speech Streaming +
native L15) **is the path; candidate B stays as the backup and future
research** (the distillation question — causal vs batch features — remains
interesting independent of A's outcome; spike B only if A fails its gates or
later as research).

The family is wider than Nemotron: the Parakeet line has native **streaming**
variants — EOU 120M (160/320/1280 ms chunks, plus an end-of-utterance head)
and Unified 0.6B streaming — while Redux, today's call ASR, is the **batch**
one we picked for accuracy/size, not because Parakeet lacks streaming. And
both families' CoreML bundles ship standalone preprocessor + encoder
artifacts (verified 2026-10-22: EOU = `streaming_encoder.mlmodelc` +
`parakeet_eou_preprocessor.mlmodelc`; Nemotron = `nemotron_coreml_<tier>/
encoder` + `preprocessor.mlmodelc`), so the `ParakeetStudentTurnModel` tap
pattern applies to both.

| candidate | feature tap | heads | size class | the unknown |
| --- | --- | --- | --- | --- |
| A. Nemotron Speech Streaming 0.6B | encoder bundle (mid-layer L15 cut — the tyger-models `front→L15` pack proves the cut is derivable) | **native** (fp16 95.9% / MLX 99.5%) | ~378–765 MB | L15 cut on the streaming graph |
| B. Parakeet EOU 120M (streaming) | `streaming_encoder` output per chunk | student heads retrained on these features | 120M-class | **parity** — and whether causal/streaming features beat the batch-Redux ones the ~49% student saw |
| C. status quo: Redux batch + student | `Encoder.mlmodelc` (shipping) | student | 183 MB | 49% parity + CPU/BNNS encode |

**The key question (user, 2026-10-22): can a streaming Parakeet variant be
TAPPED to drive the tyger models?** Decomposed:

1. *Tap* — almost certainly yes at encoder-output granularity (bundles above);
   the open detail is mid-layer access: the OG heads read Nemotron **L15**,
   not the encoder output. Verify per candidate in the spike.
2. *Feature space* — only Nemotron L15 drives the **existing** heads. Any
   Parakeet tap is the distillation route (path-C), where the 14M heads must
   be retrained on those features. Hypothesis worth testing: streaming/causal
   features suit the heads better than batch-re-encoded ones (the heads were
   trained on no-lookahead inputs) and could beat the ~49%. Empirical gate:
   label-trained heads on streaming-Parakeet features, scored on tyger-eval
   metrics (the option from the path-C follow-ups).

B's bonus if it wins: the EOU head is native endpointing, and 120M-class fits
the download budget far better than 0.6B. A wins by construction on parity
(native features) — it is the safe path if B's distillation misses.

- Spike (A): FluidAudio's `StreamingNemotronAsrManager` streams incrementally
  (`appendAudio`/`process`/partial callbacks) but its public API exposes
  **text + token timings only — no L15 embedding tap**. Options:
  1. thin raw-encoder runner over the CoreML Nemotron encoder bundle (the
     Parakeet-tap pattern in `ParakeetStudentTurnModel`),
  2. upstream a feature tap into FluidAudio,
  3. reuse the tyger-models `front→L15` encoder tier (pack format exists).
- Spike (B): same pattern over `streaming_encoder.mlmodelc`; then the
  retrain-and-gate loop.
- Compute gate: encoder at 1× RT on iPhone ANE, measured (their pipeline
  re-encodes 8 s windows per hop ≈ 50× RT — GPU-class; incremental is the
  whole feasibility story; drift is the risk).
- Drift gate: incremental-vs-re-encode decision agreement through the
  parity6/parity7-style harness, ≥99% bar — and the CoreML fp16 same-feature
  tier must clear it too (measured 95.9% at long horizon; MLX 99.5%; fix = the
  mixed-precision exemption pattern in `coreml-ane-precision`).
- Download size (measured 2026-10-22 in the shipped bundle): the 560 ms tier
  is `encoder/encoder_int8.mlmodelc` = **590 MB** (already int8) +
  decoder/joint/preprocessor ≈ 36 MB. Levers, in ROI order:
  1. **Truncate at L15** — the heads read L15 only (378M of the 652M params),
     so the tyger path never pays for the rest of the encoder (~378 MB int8).
  2. **Swap, not add** — Nemotron streaming becomes the call ASR too (drops
     Parakeet Redux 219 MB; the decoder/joint ~36 MB covers transcripts).
  3. **Quantize below int8** — the Redux existence proof: a 0.6B
     FastConformer at 2-bit ternary = 183 MB total. A quantization-aware
     retrain of the L15 slice is the big lever (~100–150 MB territory).
  4. **Packaging** — ship `.mlmodelc`, strip the `.mlpackage` copies (the
     Kokoro-pack lesson: no compiled-copy duplication).
- Budget check vs the ~550 MB ruling: swap + L15-trunc **int8** ≈
  32 (app) + 378 + 36 + 56 (heads) + 95 (Kokoro) ≈ **597 MB — over**; with
  lever 3 (2-bit) ≈ **~340 MB — under**. So the size question is not which
  model (that is decided: A) but the quantization tier.

### Phase 3 — the tyger experience (integration)

- `TurnTakerSetting.tyger` selects the streaming pair (Nemotron streaming ASR +
  Phonon); guard: warn/upgrade when a non-streaming mouth is selected.
- BACKCHANNEL hook **live (2026-10-25)**: a "mm-hm" through the streaming
  mouth — never in history (`lastSpoken` stays the agent's reply) and never
  in the second ear (`FeedbackEar` drops the cue's playback samples while it
  plays), 1.2 s gap rule, and a reply supersedes an in-flight cue.
- Barge with `onset_s` history trim; app LISTEN/SPEAK state continues to feed
  the model (never its own guess).
- Shadow → authoritative per the swap-over convention (decision-log diff gate).

### Phase 4 — verification

- `-tygerab` run 2: fixed reply-start, N=3 per engine, backchannel-cadence
  scoring (pre/post comparison).
- Device pass on iPhone: call E2E with the streaming pair, watchdog watch
  (the CPU/BNNS encode backlog was the 2026-10-22 kill), latency budget:

| step | target |
| --- | --- |
| user stops → endpoint decision | ≤ ~0.6–0.9 s (320 ms hop + debounce) |
| endpoint → first text chunk | agent-side (LLM streaming) |
| text chunk → first audio | ≤ ~50 ms (Phonon: 6 ms) |
| **turn total to first audio** | **≤ ~1.5 s** (vs 3–7.5 s today) |

## Decisions parked with the user

1. The ≥99% parity bar (keep; relax only if mixed-precision cannot clear it).

Decided 2026-10-25 (user): **the ~550 MB budget is deferred** — implement with
whatever ASR engine is available (Nemotron streaming as-is) and revisit when a
promising lightweight streaming ASR arrives "without performance loss". The
L15-slice quantization question is parked with it. Note the size anatomy
honestly: the L15-truncation lever only applies to a *separate* turn-model
encoder — with Nemotron as the call ASR the encoder runs to L24 for
transcripts (L16–24 + RNN-T are transcripts-only per the measured anatomy),
so the models total ≈820 MB as-is (626 ASR + 56 heads + 137 Phonon), not the
≈640 MB the truncated row showed.

Decided 2026-10-22: candidate **A** (Nemotron + native L15) is the path;
candidate **B** (streaming Parakeet + retrained heads) = backup + future
research.

Decided 2026-10-25 (user): **Parakeet Redux is out as the call ASR** — it has
no streaming, and the duplex loop needs streaming input. Nemotron streaming
is the call ASR ("swap, not add"). Consequence: the path-C student's Parakeet
tap goes with it — the turn-taker runs on native Nemotron L15 features (the
14M heads), or the student is retrained on them (the backup route).

Decided 2026-10-25 (user): **Kokoro is out as the mouth** — same rationale
(whole-clip, no streaming). Phonon is the mouth. Kokoro stays in the tree for
possible future use cases; its 84 MB leaves the voice-agent download budget.

## Explicitly out

BWE/upsampling (dropped on the listening verdict), VoxCPM2 (slower than
real-time), Pocket TTS (cloning-optional), 48 kHz playback (calibration note
only).
