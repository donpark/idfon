# Tap-path blockers — review request

Written 2026-11-05 for external review. Scope: replacing the private L4 encoder
cut in idfon's turn path with a tap (`tap_l4`) read from the ASR's own streaming
encoder (epic #132, tracked in #102). Every number below is measured in this
repo and reproducible from the scripts named with it. Where something is an
assumption rather than a measurement, it says so.

Reviewer backgrounds that would help: NeMo/streaming-Conformer internals, Core ML
quantization on ANE, turn-taking / dialogue-state evaluation.

## 1. What the change is, and what was already settled

The turn path runs two things per 80 ms frame: an encoder that turns audio into
features, and a small student that turns features into an 8-vector which a rules
layer converts into ENDPOINT / BARGE / BACKCHANNEL decisions.

Today the feature source is a **private 389 MB L4 encoder cut** (`docs/voice-tyger-ondevice.md`).
The goal is to delete that cut and read `tap_l4` from the streaming ASR encoder
that already runs for transcription, so there is one encoder invocation per hop
instead of two.

Settled before review (measured, not assumed):

- **One invocation is possible.** `StreamingNemotronAsrManager+Pipeline.swift:46`
  makes exactly one `encoder.prediction(from:)` call per `processChunk`; the tap
  is a second output of that same call.
- **The encoder is the same weights as the teacher's.** The adopted ASR
  (`nvidia/nemotron-3.5-asr-streaming-0.6b`) exposes taps numerically identical
  to the training shards: cosine 1.000000, max|d| 2e-3, 100% decision agreement
  (289/289 events) zero-shot.
- **The export is faithful at the reference pass.** A Core ML export at the
  reference streaming configuration reproduces `tap_l4` at max|d| 1.44e-3
  (bar 2e-3) and `encoded` at 9.6e-4, with a 22-chunk loop exact warm-started
  (3e-5). See `docs/voice-tyger-streaming-plan.md` § "Leg 1".
- **The shipping pass is different.** The shipping bundle's own metadata says
  `att_context_size [42, 13]`, `cache_channel [1,24,42,1024]`; the training
  shards record `56 / 0` with a 56-deep cache. That is blocker 2.

## 2. Blocker A — decision-level interchangeability is not attainable

**Claim we are asking you to check:** with this architecture and training
procedure, ~15% of decisions move whenever the adapter is retrained, so a
"identical decisions after the port" acceptance bar can never be met.

Evidence (`tap_gate.py`, same rules, carried state, same-kind events within
±2 frames):

| comparison | what varies | agreement |
|---|---|---:|
| wrapper 56/0 re-extract vs stored shards | nothing (control) | 100% (16/16) |
| pre-refit 56/0 ↔ 42/13 | features | 83.22% (243/292) |
| refit 56/0 ↔ 42/13 | features | 82.65% (243/294) |
| **pre@42 ↔ refit@42** | **weights only** | **84.98%** |
| **pre@56 ↔ refit@56** | **weights only** | **85.96%** |
| product: refit@42/13 vs pre-refit@56/0 | both | 82.09% (243/296) |

The adapter-only refit itself is legitimate by the project's own gates: frozen
trunk/decoder/heads byte-identical (only 4 `l4-streaming` tensors changed), probe
R² state .764 / endpoint .775, teacher agreement 56.91% versus the baseline's
57.38% on 8 sessions / 299 events, endpoint early/miss 10/4 (teacher 10/4),
mean-of-medians latency Δ +0.00, backchannel recall .32 vs .28. Corpus
calibration (T=0.8) reaches 59.56%.

**Questions:**
1. Is agreement-on-events (±2 frames, same-kind) the right measure for
   *interchangeability*? It conflates three things: feature change, weight
   change, and event-boundary jitter.
2. 299 events is our whole validation set for corpus; rates carry ~±7 pts.
   What sample size would you require to compare two decision models?
3. Is the ~15% weight-change sensitivity expected for a 150–520K-parameter
   adapter + GRU head stack trained for 20 epochs at 1e-3 with a symmetric-KL
   consistency term (λ=0.3) and per-axis loss weights? Or does it indicate our
   recipe (epochs, LR, λ, weights) is under-constrained?
4. Would you accept aggregate parity (teacher agreement + product bars) plus a
   shadowed flip budget in place of decision identity? If so, what flip rate is
   defensible for turn-taking?

## 3. Blocker B — the 42/13 shipping pass, and where our oracle comes from

The shipping pass changes the attention geometry (42 left context, 13 lookahead,
42-deep cache) relative to the reference pass (56 left, 0 lookahead, 56-deep).

Re-derived at 42/13: `cache_channel` 42 rows, attention window 50 keys (42 + 8),
relative-position table 99 rows, mask transcribed as 4 blocks of 14 with all 8
queries in the last block (all queries see all 50 keys), `cache_len` clamp 42.
The subsampling conv2d caches are **bit-identical** across passes (`torch.equal`,
shape `[1,8,1024]`) because the stage never sees the attention mask; the 8/3/1
cache-frame derivation is therefore structural, not fitted.

**The hard part:** we believe Hugging Face cannot express 42/13
(`left = sliding_window − 1 = 56`; position groups anchored absolutely), so at
42/13 **our wrapper is the oracle**. It inherits credibility only from a 56/0
equivalence check against HF (3e-5) plus the mask transcribed from the bundle's
graph.

**Questions:**
1. Is the 42/13 mask transcription above correct for NeMo's chunked-limited
   attention? (4 blocks of 14, exponential lookahead structure, 50 keys.)
2. Is `left = sliding_window − 1` genuinely a hard constraint in HF's
   `chunked_limited` implementation, or is there a supported way to express
   asymmetric left/lookahead?
3. The measured effect of the pass change alone is cosine p50 0.9925
   (p05 0.932), rel-L2 0.122, and 17 pts of decision agreement at layer 4 of 24.
   Is that plausible for a 42-vs-56 left-context change, or does it suggest we
   are not matching their mask after all?

## 4. Blocker C — Core ML cannot express our quantization grid

Three independent int8 failures, all from the same cause: the QAT grid is
**asymmetric, per-output-unit, group-16**, and `coremltools` offers symmetric
per-channel / per-block.

| artifact | expected | measured | envelope |
|---|---|---:|---:|
| student step (shared tier) | ≤2e-3 probs | **7.78e-3** | 2e-3 |
| Core ML int8 step, plain quantizer | ≤2e-3 | **1.4e-2** | 2e-3 |
| Core ML int8 encoder taps | ≈1.0 cos | cos 0.965 | — |

Passing alternatives measured today: ONNX int8 8.3e-7 (1.77 MB), MLX int8
3.6e-7 (1.76 MB), fp32 5.28 MB everywhere. Core AI int8 is unwired.

**Questions:**
1. How do you express an asymmetric per-output-unit group-16 grid in
   `coremltools`? Is `coreml_opt` the only path, and does it survive the iOS 27
   loader (below)?
2. Does ANE support asymmetric int8 weight quantization per output channel in
   practice, or is the support matrix symmetric-only?
3. If not expressible: is 5.28 MB fp32 acceptable, or would you ship ONNX/MLX
   int8 for the non-Apple tiers and fp32 on Core ML?

## 5. Blocker D — Core AI AOT containers do not load on iOS 27.0.x

Every Core AI AOT container produced here carries MPSGraph 7.1.5, above the
7.0.80 limit reported by the loader; the `.aimodel` source loads through the
macOS `coreai.runtime` JIT, the AOT `.h16s.aimodelc` does not load on
iOS 27.0.x / macOS 27. Tracked as #110. Apple-tier export therefore rests on
Core ML, not Core AI.

**Question:** known workaround or version matrix? Is this a toolchain pin, a
container-format field, or a hard loader limit?

## 6. Blocker E — device behavior is unmeasured

Host measurements only: 593,446,722 B int8 encoder artifact, `tap_l4 [1,1024,7]`,
**9.62 ms/chunk on host ANE** (9.0 documented), 20.40 ms CPU. Cache fills in
6 chunks at 42/13; per-bucket drift is flat across 64 chunks, so quantization
noise does not accumulate in the cache.

Unmeasured: iPhone ANE timing and memory at ~590 MB, thermal behavior over a
long call, and the barge-in path latency (turn decisions run on the audio path).
Also unverified end-to-end: transcription through FluidAudio's decoder with our
encoder (feature parity is measured at 9.6e-4, transcript parity is not).

## 7. Blocker F — acceptance evidence for a live call does not exist yet

All gates replay recordings. Nothing measures how a swap behaves on a real call.
A decision record now exists (`IDFON_TURN_LOG`, JSONL per 80 ms frame: 8-vector,
energy, prev state, mode, events; inert when unset, measured identical event
sequences with the flag off), and a converter to shard format
(`live_shard.py`). **No live-call data has been captured yet.**

**Question:** what is the accepted practice for gating a turn-detection model
swap in production? Specifically: what shadow protocol, what flip-rate budget,
and what human-rating sample would you consider sufficient before a swap?

## 8. Reference data (for the reviewer's own checks)

- Encoder contract at 56/0: `mel [1,128,65] f32`, `mel_length [1]`, `cache_channel [1,24,56,1024]`,
  `cache_time [1,24,1024,8]`, `cache_len [1]`, `prompt_id [1]` →
  `encoded [1,1024,7]`, `tap_l4 [1,1024,7]`, cache outs, `encoded_length`.
- Shipping bundle metadata (`FluidInference/Nemotron-3.5-…-CoreML`,
  `multilingual/560ms/metadata.json`): `chunk_mel_frames 56`, `pre_encode_cache 9`,
  `total_mel_frames 65`, `att_context_size [42,13]`, `cache_channel [1,24,42,1024]`.
- Probe quality (ridge R², mean over axes): Nemotron L4 streaming .56, Nemotron
  L24 (final) .12, parakeet L12 .55, parakeet L23 (final) .46.
- Export matrix (P7): ONNX/MLX int8 pass parity; Core ML int8 fails (1.4e-2);
  Core AI AOT does not load (#110). TurnShadow: tier-only swap inert (0 flips,
  ≤1.4e-6); int8-QAT vs fp32 student 100/84.6/80% with 2–4 ENDPOINT flips per
  1000 frames.
- Reproduce: `ports/tyger-student/{asr_tap,export_asr_tap,pass_gate,tap_gate,gate,calibrate,export_matrix,turnshadow,live_shard}.py`,
  each with a `--selfcheck` where applicable. Artifacts (gitignored, in the
  maintainer's checkout): `bench-results/asr-tap/` (artifact + wavs),
  `tap-shipping/`, `shared-shipping-refit/`, `refit-eval/`.

## 9. Known limits of this report

- The 42/13 int8 artifact was **regenerated** for the refit run because the
  first copy had been deleted; it reproduces the documented size exactly
  (593,446,722 B) and the same gate behavior, but it is a re-export, not the
  original bytes.
- The +320 ms worst-session latency bar is already missed by the **baseline** on
  our sample, so it cannot discriminate between candidates.
- Corpus `eot`/`hold` labels are sparse point events, so "commit" agreement is
  measured against teacher events, not against human annotation.
- The reference pass (56/0) remains the default everywhere; no shipped artifact
  was modified by any of this work.
