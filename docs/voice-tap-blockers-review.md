# Tap-path blockers — review request

Written 2026-11-05 for external review. **Status: held, not sent.** A first
oracle review found a defect in our own 42/13 mask implementation (§3) and two
overstatements (§4, §9); the 42/13 numbers in §2 and §3 are from the defective
build and are being re-measured. Everything else is current.

Scope: replacing the private L4 encoder cut in idfon's turn path with a tap
(`tap_l4`) read from the ASR's own streaming encoder (epic #132, tracked in #102). Every number below is measured in this
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

**Claim we are asking you to check:** one adapter-only refit moved ~15% of
decisions at identical features, so an "identical decisions after the port" bar
looks unattainable for this recipe. **Review pass 1 correctly objected that this
is one seed, one recipe, and supports "this refit did not preserve behaviour",
not "preservation is impossible"** — the training objective (§2.1) does not
actually enforce agreement with the frozen deployed model, so the experiment
that would test the strong claim has not been run.

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

**Defect found in our own implementation (2026-11-05, review pass 1).** The
wrapper asserted that mask in its docstring but implemented a causal sliding
window instead: `mask &= (kv >= qi) & (kv <= C + qi)`, which at `C=42` lets each
query see **43** keys and gives the 13-frame lookahead no effect at all. The
group condition was permissive (all 4 blocks), so the causal clamp was what
decided. Verified by evaluating the mask directly: reference pass 57 keys/query,
shipping pass 43 keys/query where the documented geometry is 50.

Fixed by replacing both bounds with per-query block bounds
(`[(block − left_blocks)·g, end of own block]`), which reduces to the sliding
window at lookahead 0 — the reference gate is unchanged at 3.53e-05, so the
56/0 numbers stand. **All 42/13 numbers in §2 and §3 predate the fix and are
being re-measured**: the re-exported artifact, the pass gate, and the refit all
have to be redone on features from the corrected mask.

The methodological point survives the bug, and is why it was worth finding: the
42/13 pass had no independent oracle. A wrong mask still produced
self-consistent numbers for weeks because nothing compared the graph to a second
implementation of that pass.
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

## 4. Blocker C — our exporter cannot yet express the quantization grid

**Corrected after review pass 1.** The earlier claim ("Core ML cannot express
it") was wrong. `coremltools` 9.0 supports asymmetric weight quantization:
`OpLinearQuantizerConfig(mode="linear", granularity="per_channel" | "per_block",
block_size=(1, 16))`. Our own encoder exporter already asks for `mode="linear"`
(`export_asr_tap.py:112`); the *student* exporter chose `linear_symmetric`
(`export_coreml.py:60`). So this is a gap in our export configuration, not a
tool limit — still open is whether an asymmetric per-block grid survives ANE
placement numerically, and how to reproduce the QAT grid's exact scale/offset
convention rather than re-quantizing.

The three failures below are real measurements, but they are not one cause: one
is the student's ONNX group-16 projection before QAT, one is the Core ML
packaging rung (worst of three: 1.4e-2 / 6.7e-3 / 5.5e-3), and one is encoder
activation drift.

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

## 8b. Questions added after review pass 1

1. **Can an independent shipping NeMo encoder reproduce our per-chunk outputs
   and cache transitions — cold start, reset, partial final chunk?** The wrapper
   cannot validate its own mask, which is exactly how the defect in §3 survived.
2. **Where do the two feature streams (`hu` microphone, `ha` playback) come
   from, and what are their real availability timestamps when ASR pauses,
   resets or drops buffered audio?** One encoder call per hop answers the
   compute question for `hu` only.
3. **Which human-visible regressions must stay below which bounds, on an
   untouched call population?** Teacher agreement near 57% cannot stand in for
   that product decision.

## 9. Known limits of this report

- The 42/13 int8 artifact was **regenerated** for the refit run because the
  first copy had been deleted; it reproduces the documented size exactly
  (593,446,722 B) and the same gate behavior, but it is a re-export, not the
  original bytes.
- The +320 ms worst-session latency bar is already missed by the **baseline** on
  our sample, so it cannot discriminate between candidates.
- Corpus `eot`/`hold` labels are sparse point events, so "commit" agreement is
  measured against teacher events, not against human annotation.
- **"Decision agreement" is `Σ matched / Σ max(|events_A|, |events_B|)`**
  (`tap_gate.py:88–114`), matched same-kind within ±2 frames. It is not frame
  accuracy and not Jaccard; a timing shift beyond the tolerance counts once as
  missing and once as spurious. Per-session counts, unmatched events and signed
  timing deltas are reported alongside it.
- **No BARGE evidence.** The eight validation shards contain ENDPOINT and
  BACKCHANNEL reference events only (no BARGE events, no `mode` track), so no
  barge-in safety claim is supported by any table in this report.
- **The pass-only effect is 70.6%**, measured on one 96 s session with the
  reference wrapper. The 83.22% figure is the eight-session artifact comparison
  and therefore also contains quantization drift; it is not a pass-only number.
- **Reproduction needs more than this document.** Every artifact named here is
  gitignored and lives in one maintainer's checkout; an outside reader needs
  the JSONL/per-session outputs and pinned library revisions to check a number,
  not a path.
- The reference pass (56/0) remains the default everywhere; no shipped artifact
  was modified by any of this work.
