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

### Reply deltas — DONE (2026-10-27)

The mouth side is done: `SpeechChunker` (the `mouth/chunker.py` port) +
chunked speak, locked by `mac/Checks/SpeechChunkerCheck`. The delta wire's
server half already existed — the gap was delivery to the client-cascade app,
now closed:

- `extension/channels/idfon.ts` `content.delta` → POST `/stream/append`
  (per-delta, retry-safe keys `(turn_id, step_index, sequence)`).
- `bridge.mjs` `/stream/append` → IPC `StreamAppend` (`crates/eve-idfon`).
- Holder `IpcFrame::StreamAppend` handler (`crates/eve-idfon/src/lib.rs`
  ~1046) → `deltas::route(peer, …)` → a registered `StreamingSpeaker`
  (`crates/idfon-voice/src/stream.rs`), or — no live backend registered —
  `cascade::push_and_send` (`crates/eve-idfon/src/cascade.rs`): throttled
  `IDFON-CALL/1` transcript snapshots to the calling app (the cumulative
  `partial`, `final: false`, 250 ms, deduped, envelope-stripped).
- App: `HybridVoice.streamPartial` (server cascade with client TTS) and the
  on-device loop's `feedUnitStream` (`VoiceAgentSession`, both apps) feed
  `ChunkFeeder` and speak chunks as they close; the woven final lands in the
  bubble the caller watched grow (`recordSpokenTurn(replacing:)`), the final
  message keeps display + correlation + the barge trim (played time
  accumulates across streamed and tail chunks).

Landed as `3be4108` (holder) + `d5a5fec` (both app loops). Acceptance's
first-audio measurement (≤ first sentence on a slow LLM) still wants a live
call timing run; the logic path is covered by `SpeechChunkerCheck` + the
suite's back-compat paths (no deltas ⇒ whole reply speaks as before).
Delivery-decision record (2026-10-26): the unit stream rides the call's
live session in the OpenAI Realtime vocabulary of the reference wire below;
the earlier alternative (correlated `speak` messages with `final?: boolean`)
is out — the protocol persists nothing, and the app weaves history from the
unit stream.

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
  2. upstream a feature tap into FluidAudio (**done** — FluidAudio #1109, merged and
     released in v0.18.3 on 2026-11-07),
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

### Tap interchangeability — measured (2026-11-05, #102 Leg 2)

`ports/tyger-student/tap_gate.py` replays **one** checkpoint on two feature sources
over the same recorded sessions (same rules, same carried state) and reports feature
drift plus decision agreement A↔B (±2 frames, same kind). The bar is the tap-swap bar:
**≥99%**.

| comparison | sessions | feature cos p50 | rel-L2 p50 | decisions agree |
| --- | ---: | ---: | ---: | ---: |
| L4 streaming re-extract vs the stored tap shards (control) | 2 | 1.0000 | 5e-6 | 100% (61/61) |
| **L15 windowed → L15 streaming** (`nemotron-3.5-asr-streaming-0.6b`) | 2 | 0.875 | 0.51 | **61.3%** (38/62) |
| **L4 windowed → L4 streaming** | 8 | 0.966 | 0.26 | **82.3%** (246/299) |

Reading: the cache-aware streaming pass is **not** interchangeable with the windowed
re-encode at either layer. The calibrated teacher heads cannot be fed the ASR's
streaming L15 (61%, far under the bar) — so the share runs through a model trained on
the streaming tap (the student's `l4-streaming` adapter), not by re-using the teacher's
heads on a borrowed feature source. L15 is the more pass-sensitive layer (cos .875 vs
.966 at L4): what the cache truncates is exactly that layer's context frontier, which is
also why the shipped cut sits at L4. The control row — the same features re-extracted
from `nvidia/nemotron-3.5-asr-streaming-0.6b` — is numerically identical to the stored
tap shards, so the drift is pass-driven, not model-driven (and the P5 "identical taps"
claim holds at feature level).

This does **not** say the streaming-trained student reproduces today's decisions; that
is a separate swap question measured in P7's TurnShadow (`docs/voice-tyger-ondevice.md`:
80–85% on the deploy adapter).

### Leg 1 — the encoder export with a declared `tap_l4` (measured 2026-11-05, #102)

Core ML exposes declared outputs only, so the tap has to be a real output of the ASR's
own streaming pass. `ports/tyger-student/asr_tap.py` reimplements that pass
(`nvidia/nemotron-3.5-asr-streaming-0.6b`, fp32 weights) as a graph with **explicit
tensor caches**; `export_asr_tap.py --export/--gate` converts and scores it.

**The I/O contract is FluidAudio's, not ours** (`StreamingNemotronMultilingualAsrManager`
+ `EncoderCacheManager` + the multilingual `metadata.json`):

| tensor | shape | dtype | meaning |
| --- | --- | --- | --- |
| `mel` | `[1,128,65]` | fp32 | 56 mel frames + the 9 pre-encode context frames |
| `mel_length` | `[1]` | int32 | 65 (the manager's `totalMelFrames`) |
| `cache_channel` | `[1,24,56,1024]` | fp32 | per-layer attention inputs (post-`norm_self_att`), right-aligned |
| `cache_time` | `[1,24,1024,8]` | fp32 | per-layer conv1d cache, post-GLU (kernel 9 → 8) |
| `cache_len` | `[1]` | int32 | valid cached frames; the manager seeds **1** (a zero frame) |
| `prompt_id` | `[1]` | int32 | LangID one-hot index (128 prompts, default 101) |
| `encoded` | `[1,1024,7]` | fp32 | prompt-conditioned frames — the tensor the decoder reads |
| `tap_l4` | `[1,1024,7]` | fp32 | raw `hidden_states[4]`, same 7 frames, pre-prompt |
| `cache_channel_out` / `cache_time_out` / `cache_len_out` / `encoded_length` | as input / `[1]` | | threaded back per hop |

The pass parameters are the **reference pass's**, not the shipping bundle's: left context
**56**, lookahead **0** (HF `sliding_window=57`, `num_lookahead_tokens=0`). That is the
pass `tap4-shards` records (re-verified this run: cosine 1.0, max|d| 3e-3 vs the stored
rows). The shipping multilingual bundle instead uses NeMo `att_context_size [42,13]`, i.e.
a 42-frame left window; its taps are a *different* feature source and a tap shipped on that
bundle needs its own shard set (see the drift table above: a pass change is not free).

Two non-obvious pieces of that pass, both baked into the graph:

- **The conv2d caches are derivable and must be.** The torch pass threads
  `NemotronAsrStreamingEncoderCausalConvPaddingCache` (subsampling Conv2d + conformer Conv1d).
  The Conv2d part is not in FluidAudio's contract, but each stage's cache frame is a fixed
  slice of that stage's input on the *current* call (frames **8 / 3 / 1** for the stem and
  the two depthwise stages; measured identical to 0.0 in fp32). Baking that is what
  "`is_first_chunk=False`" means — every chunk runs the steady-state conv framing.
  Dropping those caches (the offline-conv framing) is *not* equivalent: it yields 9 rows
  instead of 8 and drifts to cos 0.97 within a few chunks.
- **The attention cache holds layer inputs, not K/V.** Keys/values are recomputed from
  `[cache | chunk]` each call, so the 56-frame window is exact without storing per-layer K/V.

**Gates** (fixture = the 20 s runtime channels; session = `dualturn` val
`d622d1e3…`, 985 s, 2240 rows; `--gate` output in `bench-results/asr-tap/gate_*.json`):

| gate | fp32 (2.37 GB) | fp16 (1.18 GB) | int8 weights (594 MB; the shipped form is 564 MB) |
| --- | --- | --- | --- |
| (a) `encoded` vs torch, steady (≥ chunk 64) | max|d| **9.6e-4**, cos 1.000000 | — | — |
| (b) `tap_l4` vs `tap4-shards`, steady | max|d| **1.44e-3**, cos p50 **1.0**, min 0.999999 | max|d| 1.64, cos min 0.99959 | max|d| 14.8, cos min 0.949 |
| (c) chunked loop | exact from a warm start (22 chunks, max|d| 3e-5); cold start converges to fp32 noise by chunk ~30 | n/a | n/a |
| (d) extra output inert | `encoded` is read by name; the graph gains one declared output, no extra invocation | | |
| host latency / 560 ms chunk | 33–35 ms CPU | 12 ms (ANE) / 22 ms CPU | **9 ms (ANE)** / 22 ms CPU |

Reading: **(b) passes for fp32 at 1.44e-3 ≤ the 2e-3 bar** — the tap survives the trace, so
the re-export route is alive. The bar is a *precision* bar: fp16 activations already miss it
by 3 orders of magnitude (max|d| 1.6, cos 0.9996 — the tier behaves as characterized, so the
question is the adapter's tolerance, i.e. a TurnShadow run, not more export work), and naive
per-channel int8 **weights** miss it structurally (cos 0.965 — the same magnitude as the
windowed↔streaming drift that failed the tap-swap bar; per #132's rule a lossy config gets
its own calibration fit, and the project's passing int8 recipe is exemptions + QAT, not a
naive grid).

**The cold-start caveat (measured, bounded).** The torch reference's first chunk is special:
with an empty padding cache it emits 9 rows and routes a zero-padded context row into the
attention cache. A static-shape graph cannot express two shapes, so the export always runs
the steady framing: 8 rows, drop the first → 7. From a cold start (the manager seeds
`cache_len=1`) the graph's tap therefore differs from the reference for the first ~30 chunks
and converges to fp32 noise by chunk ~30 (~17 s of audio): max|d| 8.7 → 3.3 → 0.58 →
7.8e-5 across chunk buckets 1–8 / 8–16 / 16–32 / 32–64. Cold-starting both sides identically
is exact — a warm-seeded run tracks the reference to 3e-5 over 22 consecutive chunks. If the
first seconds matter, prime the encoder with ~7 silent chunks before the call, or featurize
training data from this graph (`asr_tap.py` exposes the same forward) instead of
`featurize_tap.py`'s torch loop.

Reproduce (all artifacts land in the gitignored `bench-results/asr-tap/`):

```sh
PY=ports/tyger-student/.venv/bin/python
$PY ports/tyger-student/asr_tap.py --selfcheck            # wrapper vs the torch streaming pass
$PY ports/tyger-student/export_asr_tap.py --export --precision fp32   # + fixture gate
$PY ports/tyger-student/export_asr_tap.py --export --precision fp16 --int8
$PY ports/tyger-student/export_asr_tap.py --gate bench-results/asr-tap/encoder_tap_fp32.mlpackage \
    --session-id d622d1e377001bba8c718a2fbdac0b7b          # the shards gate
```

#### Pass config: the shipping 42/13 vs the reference 56/0 (measured 2026-11-05)

> **2026-11-05 (later): every 42/13 number in this section is void.** The wrapper
> implemented a causal sliding window (43 keys/query) instead of the block mask
> documented below, so the lookahead had no effect; the mask is fixed and the
> re-measured tables — artifact 593,446,155 B / 8.92 ms ANE, product row 79.18%
> instead of 82.4% — are in `docs/voice-tyger-42-13-remask.md`. The table below is
> kept as written. The 56/0 rows are unaffected (reference selfcheck unchanged at
> 3.53e-05).

**Target decided: NVIDIA's shipping pass — 42 left / 13 lookahead, 42-deep cache, int8
weights — with `tap_l4` declared by *our* export of those weights.** Their bundle cannot
serve as the tap (Core ML exposes declared outputs only, and theirs declares `encoded`).
The pass is a `PassConfig` on the same wrapper (`--pass reference|shipping`), so the 56/0
rows above stay the documented reference every existing gate was built on.

What changes at 42/13, and what does not:

| item | at 42/13 |
| --- | --- |
| `cache_channel` in/out | `[1,24,42,1024]` (was 56) |
| attention keys | 42 cache + 8 current = 50 (was 64); relative-pos table 2·50−1 = 99 rows |
| mask | 4 blocks of 14; all 8 queries land in the last block → every query sees all 50 keys, which is the shipping bundle's `const_71` pattern |
| `cache_len` clamp | 42 |
| unchanged | subsampling (bit-identical across passes, so the **8 / 3 / 1** conv2d-cache derivation still holds — it depends on the mel framing, not the mask), `cache_time [1,24,1024,8]`, 8 rows/chunk → 7 kept, prompt projector |

Re-tracing is required (Core ML bakes shapes) but is one flag — no code path changes. The
caveat worth keeping: **HF cannot express 42/13** (`_resolve_attn_context` derives left =
`sliding_window−1` = 56, and its mask groups are absolute-position-anchored), so at 42/13
the wrapper *is* the oracle. Its credibility rests on the 56/0 equivalence (3e-5 vs HF) and
on the mask transcribed from the bundle's `const_71`.

Gate — one checkpoint (`shared-consistent-l03`, adapter `l4-streaming`), session
`d622d1e3…` 1200 frames (96 s, 17 events; ±1 event = 6%), via `tap_gate.py`:

| row | feature drift | decisions |
| --- | --- | --- |
| control: wrapper 56/0 vs the stored shards | cos p50 1.0000, relL2 0.000 | 100% (16/16) |
| **(1) pass** 42/13 fp32 vs 56/0 | cos p50 0.9925 (p05 0.932), relL2 0.122 | **70.6% (12/17)** |
| **(2) quant** 42/13 int8 sim vs 42/13 fp32 | cos p50 0.9939 (p05 0.982), relL2 0.110 | 88.2% (15/17) |
| (2b) quant, the artifact itself vs 42/13 fp32 | cos p50 0.9848 (p05 0.961), relL2 0.174 | 94.1% (16/17) |
| **(3) product** 42/13 int8 artifact vs 56/0 | cos p50 0.9741 (p05 0.917), relL2 0.227 | **82.4% (14/17)** |

Reading: the pass change alone is not free (70.6%, the same regime as windowed→streaming's
82.3%), and quantization alone also moves decisions (88–94%). **So the refit is required,
and it must fit on int8-artifact taps** — the sim is not a substitute: the artifact's extra
fp16-activation + grid drift puts it cos 0.978 away from the sim, i.e. the difference is the
same size as the effect being measured. Featurize through the mlpackage
(`pass_gate.py --emit-shards --artifact …`), per domain as P4 established.

Priming at 42/13: the cache fills in 42/7 = **6 chunks** (3.4 s, was 8). The 56/0 "7-chunk
priming" caveat was a cross-implementation artifact (HF's 9-row first chunk vs the graph's
8) and **does not recur**: at 42/13 the shard builder and the artifact share the same cold
convention, so there is nothing to prime for train/serve. A silence-primed start perturbs
the first chunks and decays 1.9 → 0.055 by ~chunk 28 — so do not prime.

Artifact: `encoder_tap_42-13_fp16_int8w.mlpackage` = **593,446,722 B** (593 MB; the 56/0 int8
form was 594 MB — same size class), `tap_l4 [1,1024,7]`, **9.0 ms/chunk on ANE**. Its tap
drift vs fp32 at 42/13 is flat per chunk bucket (11.0 / 13.4 / 15.1 / 9.8 over chunks
1–8/8–16/16–32/32–64) — quantization noise, no cache accumulation. Graph-arithmetic parity
was established at fp32 (1.44e-3 vs torch at 56/0); at int8 the weight grid is
coremltools' own (a two-line torch quantizer lands cos 0.978–0.982 against the artifact, so
it is not a same-weights reference), which is exactly why the refit featurizes through the
artifact.

#### `encoded` parity at 42/13: the graph is right, the comparison was not (measured 2026-11-06, #132)

The bundle-swap run reported this export's `encoded` at cos **0.044 / 0.609 / 0.733 / 0.732**
against the multilingual bundle's encoder and +130 word edits vs theirs. That read as "the
graph may be wrong past the tap". It is not: at 42/13 the graph reproduces its own torch
pass to **6.3e-5** (`encoded`) and **1.6e-4** (`tap_l4`) in fp32. The gap came from three
comparison errors and one real contract difference, in that order.

**The gate.** `ports/tyger-student/encoded_gate.py` runs the package the way the app does —
one 65-mel window per call, caches threaded, `cache_len` seeded 1, prompt from the model —
and scores `encoded`, `tap_l4` and every layer's `cache_channel` against the torch wrapper
at the same pass and tier, with per-bucket p50/p05/min, a row-shift scan and the worst rows.
`tools/asr-encoded-parity/compare.swift` runs two Core ML encoders on identical mel frames,
each on its own caches (the corrected form of `asr-bundle-swap --compare`). Fixture: the
20 s runtime channel, 35 chunks, prompt 101 (0 for the bundle runs); session rows from
`d622d1e3…`.

**Table 1 — our 42/13 artifact vs our own torch wrapper** (245 rows; warm = chunks ≥ 6).

| artifact | rows/call | `encoded` cos p50 | p05 | min | max|d| | `tap_l4` p05 |
| --- | --: | --: | --: | --: | --: | --: |
| fp32, keep-context (the tap pass) | 8 | 1.00000000 | 1.00000000 | 0.99999999 | 3.0e-5 | 1.00000000 |
| fp16, keep-context | 8 | 0.99924683 | 0.99829260 | 0.83548893 | 0.136 | 0.99963789 |
| fp16+int8w, keep-context (**the shipped form**) | 8 | 0.93050384 | 0.66061825 | 0.07529544 | 5.94 | 0.95952164 |
| fp32, drop-context | 7 | 1.00000000 | 1.00000000 | 0.99999996 | 6.3e-5 | 1.00000000 |
| fp16, drop-context | 7 | 0.99909055 | 0.99525606 | 0.74256288 | 0.512 | 0.99961570 |
| fp16+int8w, drop-context | 7 | 0.91400947 | 0.58658979 | 0.14189750 | 4.80 | 0.95927474 |

Graph-level: exact in fp32 — **not a graph bug**. Precision-level: fp16 is fine (p05
0.998), **naive int8 weights are not** (p05 0.66, rows whose norm jumps 1.2 → 12). The
recorded "cos_min 0.07 against its own int8 reference" is this int8 arm, not a reference
mismatch — re-scored against fp32 it is 0.075 again.

**Table 2 — where the int8 error lands** (12 chunks, fp32 wrapper; the projector isolated by
quantizing only it).

| arm | pre-projector hidden cos p05 / min | `encoded` p05 / min | max|d| |
| --- | --: | --: | --: |
| hidden perturbed by 1% of its mean | 0.999992 / 0.999990 | 0.995848 / 0.887983 | 9.7e-3 |
| int8 projector only | 1.000000 / 1.000000 | 0.978003 / 0.195491 | 3.0e-2 |
| int8 encoder only | 0.977327 / 0.930429 | 0.471059 / −0.849914 | 4.03 |
| int8 encoder + projector | 0.977327 / 0.930429 | 0.455672 / −0.815947 | 4.01 |

The projecting head is **not chaotically sensitive**: 1% hidden noise costs 0.4% of
`encoded` cosine. It *is* a cancellation-heavy projection (output rows ~1.2 in norm from
hidden ~220), so the encoder's int8 grid (hidden cos 0.977) lands at cos 0.47 on `encoded`.
The tap at layer 4 never sees it because the projection sits above it. The fix is a
quantization recipe judged on `encoded` (exemptions/QAT, per #132's rule), not the graph.

**Table 3 — our encoder vs the published bundle encoder**, identical mel, manager seed,
35 chunks. The bundle is the same checkpoint: `metadata.json` names
`nvidia/nemotron-3.5-asr-streaming-0.6b`, and its fp16 tensors match torch at cos
0.9999995 (fp16 rounding only).

| our artifact | rows/call, cache | `encoded` warm p50 / p05 | min | `cache_channel` cos |
| --- | --- | --: | --: | --: |
| fp16, keep | 8, +8 | 0.8635 / 0.5018 | 0.3156 | 0.69–0.89 |
| fp16+int8w, keep (shipped) | 8, +8 | 0.9032 / 0.5013 | 0.3256 | 0.72–0.87 |
| fp16, drop | 7, +7 | 0.9556 / 0.8740 | 0.7423 | 0.94–0.97 |
| fp16+int8w, drop | 7, +7 | 0.9832 / 0.9115 | 0.5218 | 0.97–0.98 |

**The real difference: the published graph keeps 7 rows per call, ours 8.** Their MIL declares
the same six inputs and `encoded [1,1024,7]`, but it slices the overlap row off *before* the
layer stack: 49 attention keys (42 cache + 7 current), `cache_len_out = min(cache_len + 7,
42)`. Ours keeps that row as an extra query and an extra key and caches it, so the cache
grows +8 per call and the overlap frame is attended twice. `--drop-context-row` drops it
before the stack: the cache trajectories then match exactly (8/15/22/… vs 9/17/25/…), and in
torch the two framings differ by `encoded` cos p50 **0.872** / p05 0.172 and `tap_l4`
0.9988 / 0.9784 — the framing alone is a 0.85-`encoded`-sized lever.

The remaining 1.7% is their conversion, not ours: the published encoder stores many
conv/linear weights as int8 affine dequantize (some palettized) and pads the mel offline
(`[2,1,2,1]` → 9 conv rows, keep rows 2–8); matching its precision class moves us closer
(0.956 → 0.983), which is consistent with precision, not geometry. Their quantizer was not
reproduced, so the last 1.7% is not attributed further.

**What the old comparison got wrong** (reproduced): `asr-bundle-swap --compare` seeded
`cache_len = 0` (the manager seeds 1), ran only 4 chunks — the cold-start transient; the
42/13 cache fills at 6 — and fed our 8-row cache to their 7-row graph. Corrected, same
artifact: 4 chunks/seed 0 → 0.886 / 0.840 / 0.861 / 0.391 per chunk; 35 chunks/seed 1 →
warm p50 0.903. The recorded 0.044 / 0.609 / 0.733 / 0.732 is not exactly reproducible (the
probe did not keep its mel file, and its four chunks came from a call capture rather than
this fixture), but the setup error dominates any audio choice.

**Shipping consequence.** (1) `encoded` from the naive-int8 artifact is **not numerically
interchangeable** with any fp32/fp16 encoder of the same weights (p05 0.66, min 0.075), even
though it transcribes; if the encoder is to feed their decoder, ship fp16 (1.18 GB, larger
than their 564 MB quantized bundle) or an int8 recipe validated on `encoded`. (2)
`--drop-context-row` is the drop-in fix (p50 0.983 at 593 MB), but it is **not free**: it
moves `tap_l4` (p50 0.9988 / p05 0.978 between framings; vs the stored 56/0 shards the 42/13
tap p50 goes 0.968 → 0.969 at int8, or 0.992 at fp16), so the adapter needs a 42/13
re-gate, and
it changes the **layers 0–3 prefix** (the row is dropped before layer 0): a 560 ms call
releases 7 rows not 8, a 320 ms call 4 not 5, and the prefix caches change — any prefix
artifact must be re-exported and re-gated with it. The 56/0 reference pass and its 1.44e-3
tap gate are untouched: the flag defaults off and only the 42/13 export opts in.

Reproduce (the bundle's encoder folder is public; download it once):

```sh
PY=ports/tyger-student/.venv/bin/python
$PY ports/tyger-student/encoded_gate.py \
  --artifact bench-results/asr-encoded-parity/encoder_tap_42-13_fp16_int8w_r7.mlpackage \
  --reference fp32 --drop-context-row        # table 1/2 (add --reference int8-enc|int8-all)
$PY tools/asr-bundle-swap/mels.py --wav <capture-16k-mono.wav> \
  --out bench-results/asr-encoded-parity/mels.f32 --chunks 35
swift tools/asr-encoded-parity/compare.swift \
  --a <bundle>/multilingual/560ms/encoder.mlmodelc \
  --b bench-results/asr-encoded-parity/encoder_tap_42-13_fp16_int8w_r7.mlpackage \
  --mels bench-results/asr-encoded-parity/mels.f32 --prompt 0
$PY ports/tyger-student/export_asr_tap.py --export --pass shipping --precision fp16 --int8 \
  --drop-context-row --out bench-results/asr-encoded-parity
```

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

Decided 2026-10-25, hardened 2026-10-27 (user): **the ~550 MB budget is
dropped** — it cannot be achieved at this time and "get it working first" has
higher priority. Implement with whatever ASR engine is available (Nemotron
streaming as-is); size work (L15-slice quantization, the Path-C student)
resumes only if a promising lightweight streaming ASR arrives "without
performance loss". The Path-C distillation is parked for good: 49.9% ±2-frame
decision agreement vs the 99% bar (77.4% plateau at ±16f). Note the size anatomy
honestly: the L15-truncation lever only applies to a *separate* turn-model
encoder — with Nemotron as the call ASR the encoder runs to L24 for
transcripts (L16–24 + RNN-T are transcripts-only per the measured anatomy),
so the models total ≈820 MB as-is (626 ASR + 56 heads + 137 Phonon), not the
≈640 MB the truncated row showed. (Phonon's manifest is 170 MB of files, 115 MB
distinct since 2026-11-03: the flow LM's weights ship twice and are hardlinked
— see `docs/voice-side-channel.md`.)

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
