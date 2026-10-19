# On-device port brief: TYGER on Apple silicon

Status: **brief (2026-10-18), no code.** Porting the `nineninesix/tyger` bundle
(encoder-to-L15 features + the 14M turn-taker) to Apple silicon so the on-device voice
agent gets the same decision layer the GPU tier runs. Prerequisite: the GPU box produces
the **parity reference** (per-frame head outputs on the eval corpora) — a port is only
trustworthy diffed against the original (see `docs/voice-tyger.md`, the calibration
history). Companion to that doc and `docs/voice-decisions.md`.

## What must run per hop (measured, from the bundle's `model.safetensors`)

| part | params | needed for |
| --- | ---: | --- |
| Nemotron encoder → **layer 15** | 378.0M | the decision features (the heads read L15 only) |
| encoder front (embeddings/conv) | 5.1M | input |
| turn-taker GRU + heads | 14.0M | the decisions |
| encoder L16–24 | 226.7M | transcripts only |
| RNN-T decoder | 28.2M | transcripts only |
| **decision path** | **≈ 397M** | endpoint / barge / backchannel |
| full bundle | 652M | decisions + ASR transcripts |

So the port has a natural first cut: **decisions at 397M**, transcripts later (or never —
the on-device tier can keep an existing STT and use this purely as the turn-taker; the
heads never see transcripts). Audio front-end: 128 mel bins, 80 ms frames, 12.5 Hz —
straightforward in Accelerate/Metal.

Per hop today their runtime re-encodes an **8 s window per stream** (two streams) every
320 ms. That is the number the port must beat.

## The lever: incremental encoding

The encoder is **sliding-window attention** (window 57 frames ≈ 4.6 s, 3-token lookahead,
causal). Re-encoding the whole 8 s window every hop is their simplicity, not a
requirement: with per-layer KV caching, a hop encodes **4 new frames instead of ~100** —
roughly a 20–25× compute cut on the dominant term. This is what moves iPhone from
"borderline" to "plausible with headroom", and could make the Apple port *faster* than
their GPU runtime per conversation.

Risk it carries: parity. Their validated path is re-encode-everything in fp32; cached
incremental encoding accumulates numeric drift. The mitigation is the parity harness
below — and pruning the cache every N minutes (the 8 s window bounds the drift anyway).

## Runtime choice

| | verdict |
| --- | --- |
| **MLX** (Python first, Swift MLX for app) | **do this first** — fastest path to parity + timing numbers on Mac; unified memory; one framework for Mac and iOS |
| Core ML / ANE | the *shipping* battery tier for iPhone later; stateful KV caches + flexible window shapes are fiddly; revisit when MLX numbers exist |
| ONNX Runtime mobile | fallback if MLX-on-iOS hits a wall |

**Shipping form (settled 2026-10-18).** The Python port is *scaffolding and oracle*, not
the product: its job was to pin every semantic trap cheaply (gate order, the `pad((1,0))`
left-pad, asymmetric conv padding, energy normalisation outside the model) and to be
the executable spec the real port is diffed against. Python overhead is not the hot
path (measured: the Metal kernels do the math; 30 ms/hop vs 320 ms budget). The
product forms: **Swift MLX (or Core ML/ANE) for both tiers** — Mac and iOS apps share
it, and iOS cannot ship Python at all — and **Rust for the rules/guards only** (the
tier-neutral `idfon-voice` module). Migration moment: S4.

## Precision plan (the heads are calibration-sensitive)

fp32 reference → fp16 activations → int8 weights for the encoder; **keep the GRU + heads
fp32** (14M — free, and they are the calibrated part). We watched `p_end` swing 0.85→0.95
from pause acoustics alone, so quantization is validated **per head**, not just by loss:

- per-frame |Δscore| vs the GPU reference ≤ 0.02 (all three heads);
- decision agreement ≥ 99% (fires within ±1 frame) on the eval corpora;
- harness metrics (`scripts/tyger-eval.py`) within noise: endpoint latency/early/miss,
  barge catch/false, bc precision/recall.

## The validation loop already exists

`scripts/tyger-eval.py` runs the same corpora (OtoSpeech/Switchboard val slices) through
`ReferenceEars` today; the port plugs in as a second runner and diffs per-frame scores +
decisions against the GPU reference dump. tyger-s2s ships the same pattern
(`scripts/validate/reference.py` vs `ears_batched.py`) — copy their shape.

## Integration (nothing new needed above the seam)

- The tier-neutral decider module (`idfon-voice`, already planned) hosts it; the rules
  guards live in Rust either way.
- On-device tier: `crates/idfon-director` / `OnDeviceAgentRunner` / `VoiceAgentSession`
  consume it through the same seam the GPU sidecar speaks.
- The second ear becomes *exact* on-device — the app owns the playback clock, better than
  the send-side tags the hosted tier uses today.
- Escape hatch stays open: path C (Parakeet features + retrained 14M via DualTurn's
  public training code) if the Nemotron port slips or the encoder proves unportable.

## Milestones

**S2 done (2026-10-18):** `ports/tyger-mlx/turn_taker.py` — the 14M decision model
(fuse → 3-layer GRU → five heads) ported with torch's GRU equations and the bundle's
names 1:1. `parity2.py`: **GRU batch + stepped parity max|Δ| = 2.6e-6** (stepped ==
batch: the carried-state live path is exact), **full chain (MLX encoder + MLX GRU)
per-frame 8-vector max|Δ| = 5.7e-6 vs the 0.02 budget — PASS** with 3 orders of
margin. GRU step 0.038 ms/frame; total hop ≈ 30 ms (2 encodes + 4 frames) vs the
320 ms budget, ~10× headroom before the KV lever. Decision parity follows by
construction (both paths feed the same `rules.py`). Probe lessons: `head_step`
normalises energy (`(db+50)/25` clamped) *outside* the model — callers must do the
same; Linear/GRU weights need the (out,in)→(in,out) flip at load. Remaining S2→S3
bridge: plug the MLX chain into `tyger-eval.py` as an engine for the val-slice
harness run against the `--dump-scores` reference. **Bridge done (2026-10-18):**
`mlx_ears.py` (ReferenceEars-compatible) + `tyger-eval.py --engine mlx` — the same
val slice through the ported chain scores **max|Δ| = 0.0** vs the torch reference
across p_end/yield/bc over 372 frames (1e-5 resolution); decisions identical by
construction (shared rules.py).

**S3 precision pass done (2026-10-18), judged on the real-data slice (372 frames,
per-head ≤0.02):**

| config | p_end | yield | bc | verdict |
| --- | --- | --- | --- | --- |
| fp16 encoder (norms/softmax FP32, GRU/heads FP32) | 0.007 | 0.004 | 0.010 | **PASS** |
| int8 weights: per-unit group-16 asymmetric, stem + layers.0 FP32 | 0.007 | 0.002 | 0.005 | **PASS** |
| int8: per-unit group-32 asymmetric, stem FP32 | 0.033 | 0.004 | 0.007 | FAIL (p_end) |
| int8: flat/symmetric group-64 | — | — | — | FAIL (8-vector 0.91) |

Lessons: the endpoint head pays for crude quantisation first (it is the
calibration-sensitive one — its pause-texture history repeats); real quantisation
layouts matter (per-output-unit groups along the contraction axis; flat global
groups crush small rows); early/stem tensors are outsized contributors and keeping
them FP32 is cheap. `TYGER_MLX_PRECISION=fp32|fp16|int8` selects the config.
Note: int8 here is a *storage* study (dequantised at load, GEMM in FP32); fused
int8 GEMM is a Swift/MLX shipping concern. Footprint at L15: FP32 1.5 GB → FP16
756 MB → int8-with-FP32-exemptions ≈ 380 MB.

**S3 incremental-KV study done (2026-10-18) — naive incremental FAILS the budget,
and the brief's caveat is confirmed quantitatively.** `encoder_incr.py` (per-layer
K/V + causal-conv caches, blocks stepped over new frames only; conv stem re-run per
hop so the isolated variable is the context semantics) + `parity5.py` (A/B stream of
a real 60 s conversation slice through both schemes with identical windows/mel/GRU/
rules; `--self-test` proves the incremental math against batch).

| measure | result |
| --- | --- |
| stepped == batch, identical context (self-test) | max\|Δ\| 6.1e-5 — exact |
| per-frame 8-vector vs re-encode (748 frames) | p50 **0.074**, p95 0.89, max 6.23 — **FAIL** (budget 0.02) |
| rules decisions | 5/8 aligned; 1 spurious BACKCHANNEL in the incremental scheme |
| encoder time per hop (both streams) | 53.5 ms → **1.8 ms** (30×) |

Why: with the math exact, the divergence is semantic — deep-layer attention context
is stream history instead of 8 s-window-truncated, cached frames keep their
frontier-computed representations (the stem's 11-mel-frame right-lookahead is frozen
in) while the reference recomputes them with real future, and the GRU's carried state
compounds small score drift into regime divergence (median delta already 3.7× the
budget). **Conclusion: do not ship naive incremental for the calibrated heads.**
Mitigations to measure if the lever is ever needed (iPhone battery, S4): periodic
resync (full re-encode every N hops — bounds drift; needs an N-vs-delta curve),
split-tier decisions (incremental for backchannel/gates, re-encode for p_end/yield),
or recalibrating/fine-tuning the heads on incremental-encoded features (the decision-
log → adaptation story). On Mac it is unnecessary: the re-encode is comfortably
inside the 320 ms hop.

**S4 done (2026-10-18): the Core ML port exports and is accepted.** Runtime decision
(user): **Core ML / ANE first** — the app's other models are ANE; Swift MLX audio
packages are the documented fallback. `ports/tyger-coreml/export.py` exports two
static graphs mirroring the Python chain: **TygerEncoder** (mel window (1,801,128) →
hidden L15 (1,101,1024); 801 = 8 s × 16 kHz / 160 + 1) and **TygerStep** (hu, ha,
act_db, prev_state, state → 8-vector + new state; energy normalisation baked in).
`parity6.py` accepts them against the torch oracle on real conversation (648 frames,
steady-state 8 s windows, shared carried state).

| config | per-head max\|Δ\| | decisions | per hop (both windows) |
| --- | --- | --- | --- |
| **fp32** | **0.0000** — exact | 6/6 identical | 82 ms (budget 320) |
| fp16 | 0.62 (state logits; yield 0.018, ep 0.030; p50 0.0069) | 6/6 identical | 22 ms |
| **Q8** (`quantize.py --kind linear8`: block-16 asymmetric, iOS18 target) | 0.63 (state logits; hazard 0.016, yield 0.009, bc 0.015, **ep 0.033**; p50 0.0034) | 6/6 identical | 160 ms — **0.486 GB** |

Quantisation verdict (2026-10-18, sizes cross-checked against Parakeet-0.6B GGUF
community artifacts — the Q8 tier is ~1.23 B/param there; our 0.486 GB for 397M
lands exactly on their curve): every "quantise everything" config — fp16, block-16
int8 — drifts on the latent state-logits the same way, while the *decisions* stayed
identical 6/6 in all runs. The only measured PASS at ≤0.02 was the MLX study's
int8 per-unit group-16 **with stem + layers.0 exempt** (0.007).

**Split-export experiment done (2026-10-18)** — the exemption variable, isolated:
`export.py --only front|tail|check` exports the encoder as **TygerFront** (stem +
layers.0, fp32) + **TygerTail** (layers.1..14); the tail recomputes the mask/position
embeddings (verified shape-only), and `--check` proves **split == full at 0.0**
(bug it caught: the tail must cut at layers[1:15], not [1:]). Results on
`parity6 --enc-front/--enc-tail` (front fp32 + tail Q8, 0.12 + 0.45 = 0.57 GB):

| tail config | state logits | ep | p50 | decisions |
| --- | --- | --- | --- | --- |
| Q8 per_block-16 (exempt front) | **0.145** (was 0.63) | 0.032 | 0.002 | 6/6 |
| Q8 per_channel+block-16 | 0.45 | 0.041 | 0.003 | 6/6 |

Reading: exemptions cut the state-logit drift **4×** — the MLX finding reproduced — but
the score budget still fails, and **ep is flat at 0.030–0.041 across every lossy
config (even fp16)** — a lossy-encoding floor on that head. Core ML's quantisation
layouts cannot express the one config that passed in MLX (per-output-unit group-16
asymmetric: CoreML `per_channel`+block degrades to per-row scales and got worse).

**Shipping tier decided (user, 2026-10-19): CoreML fp16 encoder on ANE + fp32 step
(the GRU/heads).** ANE power and consistency with the app's other models win over the
MLX stack's better score-guard; the fp16 drift is accepted under a *decision*
guard. The shipping pair's acceptance record (parity6, 648 frames):

| | value |
| --- | --- |
| per-head max\|Δ\| | 0.62 (state logits); hazard 0.048, yield 0.019, bc 0.037, ep 0.031; p50 0.0067 |
| **rules decisions** | **6/6 identical** |
| per hop (both windows) | **23.4 ms** (budget 320) |
| footprint | ~0.8 GB (enc fp16) + 0.06 GB (step fp32) |

The fp32 step does not reduce the state-logit drift (it enters through the encoder) —
keeping it is still right: the calibration-sensitive heads get no *additional*
noise. **Guard conditions** (the tier's evidence base): the scaled eval on real calls
(GPU box) must confirm decision agreement beyond the 60-s sample, and one battery
measurement (fp16-ANE vs an MLX prototype). **Fallback if the guard fails:** the MLX
chain (Swift translation of already-accepted Python) with the int8 g16 config that
alone passed ≤0.02 — it is the precision tier on standby, kept as the oracle for
re-exports meanwhile.

## Product work (2026-10-19)

**Startup semantics — measured, two shortcuts rejected.** The steady-state contract is
the 8 s window; the first 8 s of a call use *growing* windows in the oracle. (1) A
fixed 8 s buffer prefilled with digital silence (the app's natural implementation) is
**rejected**: vs growing windows the scores diverge hard at startup hops (state logits
up to 3.27, ep 0.49). (2) A zero-padded fixed window with an attention mask is
**broken as measured** (max|Δ| ~128 at both mel- and frame-level masks — the model's
mask path does not exclude the padded prefix as assumed; hypothesis: the
`_get_output_attention_mask` mapping). (3) The size-sane route that works by
construction: **dynamic-shape export** (`torch.export` + `ct.EnumeratedShapes` on the
33·h+1 mel lengths) — a single mlpackage with shared weights covering all startup
shapes; the per-shape trace route is impossible (24 × 1.5 GB).

**Startup solved (2026-10-19): `TygerEncoderDyn.mlpackage`.** `export.py --only
enc-dyn` exports the encoder with dynamic mel length via `torch.export` — the shape
guard itself is the finding: mel lengths must be **8k−7** (33, 41, …, 801), so the
dim is derived (`8 * Dim("_mel", 5, 101) - 7`). Conversion notes: the exported program
needs `.run_decompositions({})` (EDGE dialect); the decomposed mask builder hits a
float-met-bool `bitwise_and` (coercing override registered); and the **symbolic
`rel_shift` reshape defeats MPS type inference** — the model must be *loaded*
`compute_units=CPU_ONLY` (conversion-time CPU_ONLY is not enough). Acceptance
(`parity6 --startup --enc TygerEncoderDyn`): oracle growing windows vs the dynamic
model from hop 1 — **max|Δ| = 0.0000 on every head, decisions 6/6**, 205 ms/hop on
CPU (inside budget even unaccelerated). **The startup contract**: first 8 s on
TygerEncoderDyn (CPU, ~100 frames per call), steady state on TygerEncoder fp16
(ANE).

**Swift runtime, part 1 — mel features done.** `ports/tyger-swift/` (SwiftPM package
`TygerVoice`, consumable by both apps via an SPM path dependency). `MelFeatures.swift`
ports the extractor exactly: audio preemphasis, centered STFT (512/160, symmetric
Hann(400) in 512), power spectrum, slaney mel as a generated constant,
`log(mel + 2^-24)`, and the extractor's masked rows zeroed (it "never normalizes" —
its own comment). Parity: `scripts/tyger-swift-fixtures.py` dumps the Python
extractor's output (5 scripted cases) and `swift test` asserts ≤ 2e-3 — passing.
Trap worth remembering: use `vDSP_fft_zop` (classic C API), not the `vDSP.FFT` Swift
wrapper — the wrapper's forward returned 2×/garbage on the impulse probe.

**Swift runtime, part 2 — the feed loop done.** `TurnRuntime.swift` (same package):
growing windows to 8 s then sliding, mel features, the dynamic encoder at startup
and fp16 at steady state, four `TygerStep` calls per hop threading the carried GRU
state — mirroring `ReferenceEars.feed` exactly. Rules stay at a seam: the caller
supplies `prevState` per frame and calls `reset()` where the oracle's rules say the
context restarts. Acceptance (`TurnRuntimeTests`, 248 frames of a real conversation
slice): the Swift chain reproduces the **accepted fp16 tier's record** — maxima
inside parity6's envelope (state ≤ 0.7, probability heads ≤ 0.06) with means tight
(state ≤ 0.05, probs ≤ 0.02) — the wiring-vs-tier split: a wiring bug is O(1), the
tier's drift is not. Model I/O names are trace-generated (`input_665`, `var_114`/…)
so outputs bind by shape (8 vs 3·768), which survives re-exports. mlpackages load
only compiled (`MLModel.compileModel`) — the apps should precompile. Remaining: the
rules FFI at the seam (idfon-voice), app wiring against the media pipeline, and the
GPU-box runbook.

**Rust rules module — done.** `crates/idfon-voice/src/turns.rs` is the tier-neutral
port of tyger's `rules.py`/`session.py`/`constants.py` (frame-in → events-out:
ENDPOINT/BARGE/BACKCHANNEL/FRAME, warmup + MIN_SPEECH gates, barge onset tracking,
backchannel refractory, mode switching, barge-seeded resets). Parity by fixtures:
`scripts/tyger-rules-fixtures.py` *runs the Python rules* over scripted streams and
writes `crates/idfon-voice/tests/data/turns-fixtures.json`; `cargo test -p idfon-voice`
asserts identical events — **8 cases / 1386 frames pass byte-identical**, including a
400-hop random stream over every branch. Rounding note: Python's `round` is
ties-to-even — the port rounds via `format!` (IEEE, same behavior). Next: expose via
`apple_ffi` for the apps, and port the relay's guards/adaptation into the same module.

Reading: the export is provably faithful (fp32 zero-delta), and the whole fp16 gap is
precision — amplified on the latent state-logits, the calibration-sensitive heads
(its history repeats). Shipping: **fp32 is already real-time** (14× headroom) and
exact — ship it for correctness; fp16/ANE is the battery tier (52× faster, decisions
agreed on this sample) to pair with the decision-agreement guard, not the score guard.
Export gotchas: coremltools needs `new_ones` registered by hand (mask builders,
cast to bool); Builder ops take keyword args (`mb.cast(x=…)`); `state` is a reserved
Core ML name (renamed `state_workaround`); the processor yields 801 mel frames for
8 s. Follow-ups: enumerated startup shapes (growing windows), Swift runtime wiring
into the apps (media pipeline), the rules module in Rust.

**S1 done (2026-10-18):** `ports/tyger-mlx/` — the encoder→L15 port (faithful
translation of transformers' `NemotronAsrStreamingEncoder`, offline mode) with
`parity.py`. **Parity PASS**: max|Δ| = 9.7e-5 (noise) / 6.9e-5 (speech) vs the torch
`hidden_states[15]` — the exact tensor the heads read. **Timing: 14–15 ms per full-window
encode vs 359 ms torch-CPU (and ~111 ms MPS)** — a hop (2 encodes + GRU) ≈ 35–40 ms
against the 320 ms budget, ~8× headroom *without* the incremental-KV lever. The spike's
cheap kill point is decisively passed. Debug notes worth keeping: torch `pad((1,0))` is
*left* padding (the `_rel_shift` bug that cost an hour); ReLU sits after the whole
depthwise-separable layer, not between the convs; mlx `conv1d` weight layout is
`(C_out, K, C_in/g)` and `layer_norm` lives in `mx.fast`.

| | what | effort |
| --- | --- | --- |
| S1 spike | MLX encoder → L15 on fixed clips; parity vs reference; hop timing on M-series | ≤ 1 week |
| S2 | GRU + rules + eval-harness parity on a val slice | days |
| S3 | streaming: incremental KV, window cache, real-time target with headroom | 1–2 weeks |
| S4 | iPhone: Swift MLX or Core ML/ANE + power/thermal budget | 2–3 weeks |

≈ 4–6 engineer-weeks to real-time on Mac; +2–3 for the iPhone shipping tier. S1's output
tells us whether to proceed — it is the only milestone that can kill the project cheaply.

## Risks

1. **Incremental-cache parity drift** — the whole speed lever; contained by the parity
   harness and bounded caches.
2. **Quantization drift on calibrated heads** — mitigated by keeping the GRU fp32 and
   per-head acceptance.
3. **ANE shape flexibility** (sliding window, stateful KV) — fallback to MLX on the GPU
   core, at a battery cost; decided after S4's measurements.
4. **Thermal/battery on iPhone** — 397M int8 at one hop per 320 ms is light for the GPU
   but continuous; the budget is part of S4's exit criteria.
5. Scope creep: transcripts (the extra 255M) are explicitly out of S1–S3.

## Definition of done

- Parity: the three acceptance numbers above hold on held-out eval sessions.
- Real time: 320 ms hops with ≥ 2× headroom on an M-series Mac; iPhone meets its budget.
- The GPU-tier gate metrics are preserved (the port is not a downgrade in decisions).
- The decision log schema records which engine produced each decision (`engine: mlx|gpu`)
  — the fine-tuning data stays comparable across tiers.

## References

- `docs/voice-tyger.md` — the tier design, the calibration history, the traits/adaptation
  loop this plugs into.
- `docs/voice-decisions.md` — the decision inventory and guardrails.
- tyger-s2s: `app/plugins/ears/tyger/` (`asr.py`, `rnnt.py`, `controller.py`,
  `rules.py`) and `scripts/validate/` (the parity pattern).
- Bundle: `huggingface.co/nineninesix/tyger` (OpenMDW 1.1 — ports and derived weights
  allowed; keep attribution).
