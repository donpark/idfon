# On-device port brief: TYGER on Apple silicon

Status: **as-built (2026-10-21).** The port exists and is gated: the numeric
chain in three runtimes (`ports/tyger-swift`: `CoreMLTurnModel`,
`MlxTurnModel`, `CoreAITurnModel`), the exports (`ports/tyger-{coreml,coreai,
mlx}`), the decision guards (`parity6`/`parity7`), and both apps' `TurnShadow`
shadows. The brief below records the reasoning that produced it; the dated
rulings are the history — **the tier table is the current state.**

## Tier state (current)

The shipping decision layer by platform. This table is authoritative; the
rulings and measurements further down are the record that produced it.

| Platform | Tier | Guard / note | Size |
| --- | --- | --- | --- |
| **All platforms (2026-10-22; removed 2026-10-25)** | ~~path-C student~~ deleted: a Parakeet-tap copycat with ~50% decision parity and a backchannel head that never fired | — | — |
| **macOS 27+ / iOS 27+** | **CoreAI fp32, L4 cut** — `bench-results/tier-l4/coreai` (the shipped pair: `TygerEncoderL4` = `hidden_states[4]`, max|Δ| 0, + `student_step`) | encoder exact; student 56.6% live event agreement (13 captures) | 433 MB |
| — fallback | CoreAI fp32 L15 — `bench-results/coreai` | **100%** (917/917 identical frames) | 1.53 GB |
| — fallback, opt-in rung | CoreAI fp16 (fp16 compute, fp32 I/O) — `IDFON_TURN_PRECISION=fp16` | 99.67% aligned ±2 frames on the corpus — but **0 endpoints on the corner gate** (fp16 `p_end` drift); opt-in only | ~0.77 GB |
| macOS 14–26 | MLX int8-g16 (stem + layers.0 fp32) — `TygerVoiceMLX` | 99.5% (3 flips in 917) | 1.58 GB on disk¹ |
| iOS 18–26 | CoreML fp16 encoder (ANE) + fp32 step — `TygerVoice` | 95.9% (21 flips; accepted jitter) | ~0.86 GB |

¹ the artifact stores dequantized fp32 weights ("380 MB" is the quantized
weight estimate, not the file).

The `pathc` student was removed 2026-10-25 (user ruling: a Parakeet-tap
copycat with ~50% decision parity; its backchannel head never fired) and is gone
from the packed manifest. It is **not** the P1 distilled student
(`ports/tyger-student`, `docs/voice-decision-model.md`): that one reads the same
1,024-d encoder tap (L15; L4 for the shipped L4 student) and emits the same
8-vector, inside the product bars.

**Step swap (issue #104, 2026-11-01)**: the encoder tier is now the **L4 cut**
(`TygerEncoderL4`, `hidden_states[4]`; the L15 `bench-results/coreai` is the
fallback), and every step loader now prefers the student over the teacher step —
`StudentStep.mlpackage` (CoreML), `student_step_float32.aimodel` (CoreAI, with
its AOT container beside it), `StudentStep.onnx` (eve TS bundle) — and falls
back to the teacher step, then to classic turn-taking. The carried GRU state is
read from the artifact (CoreML model description, the bundle's `io` contract)
or sized by step family (CoreAI: student 2x256, teacher 3x768). Thresholds are
per model and travel with the step: the P1 L15 student's live-calibrated triple
is **0.85/0.4/0.4** (`ports/tyger-student/student.traits.json`; the teacher's
0.9146 lost 9 pts of event agreement on real call captures —
`bench-results/live-calibration.md`), while the **L4 student the live bundle
ships** carries its own **0.75/0.5/0.5** (`ports/tyger-student/student-l4.traits.json`,
byte-identical to the published 182-byte file) — the pooled 13-session live fit.
Barge is measured on both: 20 live-call onsets (student 2/20 = teacher 2/20 at
barge_thr 0.5; the student fires 2 false barges vs the teacher's 16, and at
matched false-fire budgets the catches match — the student's yield head is
compressed (L4 0.42×teacher), so a common threshold under-reads it) and Open Yap
1K (59 onsets; L4 and L15 indistinguishable). See
`bench-results/barge-live.md`.

The ASR's own encoder does **not** expose L4: FluidAudio's
`StreamingNemotronAsrManager` returns text and token timings, and the compiled
encoder has no L4 output. The shipped L4 cut is a private export of the same
Nemotron encoder; the true ASR tap is still open (#102).

**Core AI AOT packaging constraint (2026-11-01 incident).** The AOT containers
this machine produces (`MetalToolchain-v27.2.47.0`, `coreai-build-3605.6.3`)
carry **MPSGraph package version 7.1.5**; iOS 27.0.1 and macOS 27.2 accept at
most **7.0.80**, and the Core AI loader does not error on the mismatch — it
**segfaults** inside MPSGraph (`EXC_BAD_ACCESS` on an `llvm-worker` thread) and
takes the app down (live-call crash, `Idfon-2026-11-01-171742.ips`; the installed
tier was exactly the two 7.1.5 containers). The October containers from the
older toolchain (`MetalToolchain-v27.1.266.1`, 7.0.63) load fine — the 30k-call
soak passes on them.

- Code mitigation: `CoreAITurnModel.select` treats a package above 7.0.80 as not
  loadable (`IDFON_TURN_AOT_MAX` raises the gate), so the tier is refused and the
  app falls back instead of crashing; `VoiceModelGate.start` downloads the
  **CoreML** tier on iOS while the Core AI files on disk are not loadable.
- Real fix: rebuild the AOT containers with a toolchain that emits ≤ 7.0.80 (the
  27.1 Metal toolchain, root-only here) and republish. `TygerModelStore.fetch`
  keeps files that already exist, so a same-name republish will not replace an
  installed bad container — bump the artifact names (or verify hashes) when
  shipping the replacement.

- **Loading**: `CoreAITurnModel` loads the float32 pair by default (the
  2026-10-27 ruling: the fp16 pair drifts `p_end` ≈ 0.03 and never ends a
  margin turn on the corner gate); fp16 is opt-in via
  `IDFON_TURN_PRECISION=fp16` and the fallback when only it is installed.
- **Delivery (phone)**: `TygerModelStore` fetches the tier from the pinned
  `donpark/tyger-models` manifest (packed by `scripts/pack-tyger-models.mjs`)
  into `TygerModelStore.root` — `Library/Caches/tyger-models`, cache-class
  (the weights are re-downloadable) — behind the `VoiceModelGate` download
  approval (2026-10-27 rule: downloads start from the leading user action,
  never at call start). The manifest ships the fp32 pair plus the A18
  (`.h17p`) AOT containers — loading a source `.aimodel` without one triggers
  the per-load ANE compile leak (`docs/disk-hygiene.md`) — and side-loads go
  to the same directory. `TygerModelStore.migrateLegacyLayout()` (app launch)
  moves the older layouts in (pre-2026-10-27 `Documents/tyger-models`, the
  earlier Application Support root) and deletes the product-dead `pathc` tier.
  **Reclaim (2026-10-27)**: the tier is cache-class on purpose — iOS purges
  `Library/Caches` content automatically in low-storage situations (Apple
  storage guidelines; community-confirmed — there is no file-level override:
  `NSURLIsPurgeableKey` is read-only and reads `false` even in Caches, and
  nothing can exempt a cache file from the purge), so the system's condition
  (low storage) and action (delete) handle the common case, and the gate
  re-fetches on the next voice use. `TygerModelStore.reclaimIfDiskLow()` at
  launch covers the deterministic edge: condition =
  `volumeAvailableCapacityForImportantUsage` < 2 GB, action = delete the
  store root. Non-re-downloadable packs (phonon) stay in
  Application Support — never purged — exactly the split the SO guidance
  prescribes. Heavier Apple-native option if that is not enough: Background
  Assets (`AssetPackManager` — ODR's designated successor: manifest-driven
  packs with system-scheduled download and system eviction under pressure).
  Provisioned on the iPhone 16 (iOS 27): 2026-10-27.
- **Guard metric**: agreement with the fp32 reference through the same rules
  (same-kind decisions within ±2 frames = one) over the `dualturn-otospeech`
  corpus, `ports/tyger-coreml/parity7.py`; the bar is **≥99%**.
- **Superseded rulings**: the S4 single-tier CoreML fp16 lock and the
  2026-10-19 platform-split ruling below both predate the CoreAI tiers; their
  measurements stand.

## What must run per hop (measured, from the bundle's `model.safetensors`)

> This is the L15 teacher/fallback anatomy. The shipped L4 cut stops at layer 4:
> 106.0M params, 389 MB fp32, and the L4 student reads `hidden_states[4]`
> (`bench-results/tier-l4/coreai`).

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

Per hop today their runtime re-encodes an **8 s window per stream** every 320 ms — but
with three optimisations this doc previously missed (`~/dev/github/tyger-s2s`,
`app/plugins/ears/tyger/`), which is why their real cost is lower than "two encodes per
hop":

1. **Both ears go through one batched call** — the user and agent windows are
   equal-length, so they are stacked (`asr.py:65-67`), not encoded twice.
2. **The encode stops at layer 15 of 24** (`constants.py: L15 = 15`, "encodes stop
   there"), via a forward hook that raises (`asr.py:15,29-32`): ~1/3 less encoder work
   per tick than a full-depth pass. Their turn-taker is a *prefix* design already, done
   in-process rather than by exporting a smaller graph.
3. **All-zero agent windows are cached per length** (`asr.py:27-28,67-68`): while the
   agent is silent, its window is encoded once and reused, halving the work in the
   listen case.

So the thing to beat is smaller than it looked, and two of their tricks transfer to ours
directly: cache the silent playback ear instead of re-encoding silence, and batch the two
ears into one prediction (batch dimension 2 with concatenated caches) rather than calling
twice.

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

**Shipping tier decided (user, 2026-10-19; superseded — see Tier state above):
CoreML fp16 encoder on ANE + fp32 step
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

**Scaled eval (2026-10-19, `parity7.py`: 24 sessions × 3 min real conversation,
920 decisions, shipping chain vs fp32 reference through the same rules): FAIL as
defined** — 95.9% decision agreement within ±160 ms (bar: ≥99%); 88.9% fire at the
identical frame, 98.5% at ±2.6 s, leaving 21 genuinely divergent events (~2.3%, 13
of 24 sessions; the other 11 are exact). Margin analysis on the divergent frames
puts every flip **at the decision boundary**: the driving prob differs between tiers
by 0.01–0.03 exactly where it straddles its threshold (bc 0.49 vs 0.50; ep 0.91 vs
0.92 against 0.9146) — the accepted drift envelope itself, amplified by the
debounce (a 2-consecutive-frame rule turns a 0.01 bias into a whole missed ENDPOINT)
and by gate-state cascades after a flip. Consequences seen: endpoint timing jitter
80 ms–2.5 s, occasional split/merged turns (~1 episode per 10 min), spurious or
missing backchannels (~6 per 72 min). No divergence was found away from a threshold
— this is boundary jitter, not a new failure mode. Open question before switching
tiers: whether MLX int8 g16 (drift 0.007) clears the 99% bar in the same harness, or
whether every lossy tier lands ~97–98% and the bar is only met by exact arithmetic.

**MLX fallback in the same harness (2026-10-19, `parity7.py --cand mlx`): PASS** —
99.5% within ±160 ms, 97.8% at the identical frame, 99.8% saturated. 3 genuinely
divergent events in 917 (all backchannels, all sub-0.01 flips at the 0.50 boundary);
zero endpoint-structure differences; 19 of 24 sessions exact. The margin analysis
settles the open question: boundary jitter is a property of every lossy tier
(thresholds sitting exactly at 0.50 flip under any arithmetic difference), but the
drift size sets the rate — fp16's 0.02–0.06 envelope produced 21 divergent events
including split/merged turns; int8 g16's 0.007 produced 3 mild ones.

**Ruling (user, 2026-10-19): the shipping tier is now platform-split**
(superseded on OS 27+ by the 2026-10-21 CoreAI fp16 ruling below). Mac =
MLX int8 g16 (no battery constraint, takes the guard-passing tier); iOS = CoreML
fp16 / ANE (battery over precision — accepts the measured ~2.3% decision divergence:
split/merged turns ~1 per 10 min of conversation, wrong/missing backchannels ~6 per
72 min). Supersedes the single-tier fp16 decision. Remaining work for the mac tier:
Swift MLX translation of `ports/tyger-mlx/` (the accepted Python chain, ~450 lines:
encoder.py, turn_taker.py) behind the existing feed loop; acceptance = the same
harnesses (TurnRuntimeTests fixtures + parity7). Still pending for both tiers: the
battery measurement on a live call and the GPU-box runbook.

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

## Core AI tier (2026-10-19, OS 27+)

**User ruling**: voice features target Apple's Core AI runtime (`.aimodel`) on
iOS/macOS 27+; older OSes keep today's stack (mac = MLX int8-g16, iOS = CoreML
fp16/ANE). Core AI runs GPU-or-NE and unifies mac + iOS under one export stack.
Reference collection: `github.com/john-rocky/coreai-model-zoo` (its
`conversion/nemotron_asr/` is a port of this exact encoder).

**Toolchain** (`ports/tyger-coreai/`, env recipe + landmines in its README):
python 3.12, coreai-core 1.0.0b3 + coreai-torch 0.4.3 + coreai-opt 0.2.0 +
apple/coreai-models checkout; `export_turn.py` exports the two graphs
(encoder with `dynamic_shapes` = the startup contract in ONE asset; step) and
gates them via `coreai.runtime` on this Mac.

**The record** (gate transcripts: `ports/tyger-coreai/GATES.md`):

| Gate | Result |
|---|---|
| export_step vs torch (gpu) | max\|Δ\| 0.0 |
| export_encoder vs torch (gpu+cpu, real audio) | max\|Δ\| 1e-4, cos 1.0 |
| Swift `CoreAITurnModel` vs the oracle (248 frames) | exact |
| Swift soak: 30k step calls, one process | clean (the Python binding's leak is harness-only) |
| decision guard vs the fp32 reference (24 sessions / 72 min, 53,952 frames) | **917/917 decisions at the identical frame (100%)**; per-head max\|Δ\| 6e-5 |

Posture: **GPU** — the ANE compiler hits an internal error on the dynamic
encoder (`dummy_pool` mapping failure) and the CPU specialization fails on the
step graph; the zoo's gates show the same NE posture (below bar → ship GPU).

**Ruling (user, 2026-10-21): the OS 27+ shipping tier is CoreAI fp16** (encoder
+ step, fp16 compute behind fp32 I/O — `EncIO32`/`StepIO32` in
`export_turn.py`). The decision guard on the fp16 pair: 917/919 aligned ±2
frames = **99.67%**, 96.95% same-frame, 4 boundary-flip decisions (1 missed +
3 spurious) over the 24-session corpus — passes the ≥99% bar at half the fp32
size (~0.77 GB), and slightly better aligned than the MLX int8-g16 tier
(99.5%). `CoreAITurnModel` prefers the float16 assets and falls back to the
float32 pair (the exact tier). Full tier state: **macOS 27+/iOS 27+ = CoreAI
fp16** (fp32 available as the exact tier); pre-27 mac = MLX int8-g16; pre-27
iOS = CoreML fp16/ANE (accepted jitter).

**Landmines** (all in `.agents/skills/coreml-ane-precision`):
`expectFrequentReshapes=true` corrupts dynamic-model GPU execution (exact with
it off — Apple's guidance is wrong here); the Python binding leaks ~1 IOSurface
per inference call and the drain is system-wide (harness runs must be sequential
and process-sharded; the Swift runtime does not leak); `reference_inputs` keys
must match `forward`'s parameter names; transformers 5.20.1; b1/0.4.0 pinned
pair crashes in the compiler (use b3/0.4.3); device loader landmines from the
zoo: >2 GB multi-I/O bundles fail to load (split) and terse input names are
rejected.

Remaining: device AOT gates (`xcrun coreai-build compile` + an on-device run in
the transcript discipline). The fp16 rung (size play: 1.53 GB → ~0.77 GB) is
exported and gated (2026-10-26: both rungs in `bench-results/coreai`, the
loader's path; `ports/tyger-coreai/GATES.md`).

## Export matrix and the swap-over gate (2026-11-05, #161)

The step is one model behind the 8-vector seam; each platform runs it through its own
runtime. `ports/tyger-student/export_matrix.py` produces and gates the whole matrix in
one run; `ports/tyger-student/turnshadow.py` is the diff harness every swap-over goes
through. Both are ordinary repo scripts and both write only to the gitignored
`bench-results/`.

**A cell = adapter × tier × variant.** Adapters are the converged int8 checkpoint's
(`l15-windowed`, `l4-windowed`, `l4-streaming` — the deploy tap last); tiers are ONNX /
Core ML / Core AI / MLX; variants are `int8` (the deployable rung: #145's QAT fine-tune
on the per-output-unit group-16 grid, dequantised in-graph so compute stays fp32) and
`fp32` (the converged fp32 student at the tier's native precision). The gate is P4's
envelope, applied per cell against the cell's *own* torch source:

| check | bar |
| --- | --- |
| per-head probs (hazard/yield/bc/p_end) vs fp32 torch, carried state | ≤ 2e-3 |
| state-logit argmax flips | 0 |
| crossings of the adapter's fitted traits thresholds | 0 |

`matrix.json` also carries one tier-independent row per adapter: the int8 source
checkpoint vs the fp32 student it was fine-tuned from. That is the QAT cost, not a
packaging cost — the cell gates measure packaging.

**Exports ≠ loads.** Two separate facts per cell: the artifact exists and has N bytes;
the tier's runtime opens it. Core AI is the case that forces the distinction — the AOT
container embeds an MPSGraph package version, and anything above **7.0.80** is refused
(or segfaults) by the 27.0.x loaders (#110). The matrix reads that version out of the
container instead of loading it.

**Tap input layout** (identical for every tier — the seam is the contract):

| input | dtype | shape | meaning |
| --- | --- | --- | --- |
| `hu` | f32 | (1024,) | caller stream, one 80 ms frame |
| `ha` | f32 | (1024,) | agent stream (the second ear) |
| `act_db` | f32 | scalar | raw frame energy, dB |
| `prev_state` | i64 | scalar | floor state the rules fed back (0–3, 4 = begin) |
| `state` | f32 | (2,1,256) | carried GRU state |
| → decision | f32 | (8,) | 4 state logits, hazard, yield, bc, p_end |

One tap frame in, one 8-vector out, 12.5 Hz. The adapter is **524,800 params (2.1 MB
fp32)** and the shared trunk + decoder **794,633 (3.2 MB fp32)** — the marginal anatomy a
new ASR pays for. The tap identity per adapter (layer, pass) is in `matrix.json`.

### The matrix (quiet-machine pass, 2026-11-04)

int8 source: the QAT fine-tune of the λ=0.3 shared student (`shared-qat-ft/`, 20 ep @
1e-4, seed 0, `--consistency 0.3 --qat 16`, warm-started from `shared-consistent-l03`;
weighted loss 0.15951 → 0.15936 — converged from the first epoch, the "zero quality cost"
shape #145 measured). Gate frames: 248 carried-state frames per cell, from one recorded
session of that adapter's val split. Machine quiet (load average 2.3 on 14 cores).

| tier–variant | bytes | probs max\|Δ\| (l15 / l4w / l4s) | argmax · threshold flips | ms/frame (l15 / l4w / l4s) | loads |
| --- | ---: | --- | --- | --- | --- |
| ONNX int8 | 1.77 MB | 8.3e-7 / 6.6e-7 / 6.0e-7 | 0 · 0 (all) | 0.194 / 0.195 / 0.194 | yes (ORT CPU) |
| ONNX fp32 | 5.28 MB | 7.8e-7 / 6.3e-7 / 8.3e-7 | 0 · 0 | 0.041 / 0.041 / 0.042 | yes |
| Core ML fp32 | 5.31 MB | 8.3e-7 / 4.2e-7 / 6.0e-7 | 0 · 0 | 0.074 / 0.073 / 0.071 | yes (macOS, ANE) |
| Core ML int8 | 1.71 MB | **1.4e-2 / 6.7e-3 / 5.5e-3** | 0 · 0 | 0.424 / 0.427 / 0.426 | yes — **fails the envelope** |
| Core AI fp32 | 5.29 MB | 2.4e-7 / 1.8e-7 / 3.0e-7 | 0 · 0 | 0.986 / 0.983 / 0.979 | source: yes; **AOT: no** |
| MLX int8 | 1.76 MB | 3.6e-7 / 2.1e-7 / 2.4e-7 | 0 · 0 | 0.366 / 0.361 / 0.360 | yes |
| MLX fp32 | 5.28 MB | 3.3e-7 / 2.1e-7 / 1.8e-7 | 0 · 0 | 0.360 / 0.359 / 0.359 | yes |

Readings:

- **The int8 rung is tier-faithful.** ONNX and MLX store the QAT grid and reproduce the
  QAT model to 2e-7…8e-7 with zero flips — three orders inside the envelope. int8 costs
  nothing but bytes here, because QAT already put the weights on the grid.
- **Core ML cannot express that grid.** `coremltools`' only linear weight scheme is
  symmetric (per-channel/per-block) and the artifacts land at 5.5e-3…1.4e-2 — they
  *export* (1.71 MB) and *load*, and they fail the envelope. This is the one cell where
  "exports" and "deployable" diverge; Core ML stays on its fp32 form (what the apps load
  today).
- **Core AI's AOT containers do not load on the shipping OSes.** All three adapters'
  `.h16s.aimodelc` carry **MPSGraph 7.1.5**; the 27.0.x loaders accept at most 7.0.80
  (#110). The macOS runtime (`coreai.runtime`, JIT) loads the source asset and passes
  every cell — so the tier is export-covered and macOS-load-covered, and *not*
  device-load-covered. That is a toolchain fact, not a student fact.
- **ms is a macOS-host number** for every tier. iOS device numbers are not measured here
  (device-only builds); the Core AI device path cannot be measured until the AOT
  toolchain emits ≤ 7.0.80.
- **QAT distance (tier-independent)**: the int8 source vs the fp32 student it was
  fine-tuned from differs by up to 6.4e-2/8.5e-2/6.9e-2 (l15/l4w/l4s) per-head with 1–2
  state argmax flips and 4–6 trait-threshold crossings per 248 frames. The packaging
  gates are clean; the checkpoint swap is where the decisions move (next section).

### TurnShadow: the tier is free, the checkpoint is not

Two shadow passes over the same recorded sessions (2 sessions × 500 frames each, ±2
frames, the adapter's fitted traits, each side replaying with its own carried state and
rules feedback):

**(a) tier-only** — candidate artifact vs its *own* torch source:

| cell | agreement | flips | p_end max\|Δ\| |
| --- | ---: | --- | ---: |
| ONNX int8 | 100% (14/14, 13/13, 15/15) | none | ≤ 1.4e-6 |
| MLX int8 | 100% | none | ≤ 3.9e-7 |
| Core ML int8 | 100% | none | 9.4e-3 … 1.6e-1 (envelope fail) |

So the int8 tier changes **no decisions at all** relative to the model it packages. Any
decision change a swap introduces is the checkpoint, not the runtime.

**(b) swap** — the deployable int8 artifacts vs the currently deployed fp32 student:

| adapter | agreement | flips (1000 frames) | p_end mean / p95 / max | state logits mean / p95 |
| --- | ---: | --- | --- | --- |
| l15-windowed | 100% | none | 1.0e-2 / 4.4e-2 / 1.3e-1 | 0.10 / 0.46 |
| l4-windowed | 84.6% | 2 ENDPOINT missing, 2 spurious | 1.0e-2 / 4.9e-2 / 1.3e-1 | 0.12 / 0.54 |
| l4-streaming | 80.0% | 1 ENDPOINT missing, 2 spurious, 1 BACKCHANNEL | 1.1e-2 / 6.3e-2 / 2.8e-1 | 0.14 / 0.71 |

**The fine-tune is what moves the decisions.** The same grid applied without the extra
20 epochs (plain projection of the fp32 checkpoint, no QAT) reproduces the deployed
student's events exactly on the same 1000 frames — 100% agreement, 0 flips, p_end max
1.4e-2 — while failing the packaging envelope at 6.05e-3, because its weights are
off-grid by construction. The two candidates bracket the problem: projection keeps
behavior and drifts probabilities; the fine-tune keeps the grid and moves behavior. A
swap that changes nothing above the seam therefore needs a QAT run **constrained to
reproduce the deployed student's decisions** (a consistency term against the fp32
checkpoint, or a much shorter/lower-lr fine-tune), not a longer one.

### The swap-over gate

`turnshadow.py` replays a candidate artifact and the authoritative student (the fp32
shared student the tier ships today) over recorded sessions through the same rules, and
reports per-axis drift, per-event flips and per-frame cost. It is shadow-only: nothing
it does can change a call, and classic turn-taking stays the fail-open path untouched.

A swap is **blocked** when any of these holds:

- an ENDPOINT event is missing or extra beyond ±2 frames (turn structure changes),
- a BARGE event is missing or extra (the playback stop is the safety path),
- per-head drift exceeds 2e-3 (the P4 envelope),
- p95 per-frame step cost exceeds 8 ms (the 80 ms frame with 10× headroom).

BACKCHANNEL flips are reported and counted, never averaged away: every lossy tier shows
sub-0.01 boundary jitter on the bc head (parity7's finding), so a bc flip is a product
decision about the backchannel threshold, not a packaging failure.

As of this pass **no int8 candidate clears the gate** on the recorded sessions: the
faithful-to-source QAT artifacts change endpoint decisions, and the
faithful-to-behavior projection fails the envelope. That is the gate working as
intended — the matrix says the packaging is done, TurnShadow says the model swap is a
product decision plus one more training change.

### The live-call record (`IDFON_TURN_LOG`, #102)

Every gate above replays *recorded* frames, so none of them can say what the product
actually decided during a real call — and a model swap measured only on recordings
cannot claim "no behavior change" against a baseline nobody captured. The instrument
for that baseline is the record, and it must exist **before** any app-side swap:

- **Flag:** `IDFON_TURN_LOG=<path>`, read by `TurnTrace.fromEnvironment`
  (`ports/tyger-swift`, shared by both apps). Unset is the default and is inert: no file,
  no branch in the frame path. A bare name (no `/`) resolves into the app's Documents
  directory; a full path is used as given. Both apps wire it in `TurnShadow`'s init and
  close it in `stop()`; the tier identity (`tier`/`rung`/`step`/`traits`) travels in the
  session header.
- **Record:** one JSON object per line. The header (`rec: "session"`) carries the session
  id, `started_at`, `origin_ns` (the monotonic origin every `t_ms` is measured from),
  `rate`/`hop`, app id/build/os, and the tier meta. Each frame (`rec: "frame"`) carries
  `i` (the engine's 1-based counter), `t_ms`, `out` (the 8-vector), `act_db`, `prev`
  (the state the step consumed), `left`, `mode`, and `events` (the non-FRAME events that
  fired on it: kind + frame). No audio and no encoder features — the paired
  `TurnCapture` stereo wav is the audio. Frames are buffered and appended on a utility
  queue, flushed per hop; nothing on the capture path waits for the disk.
- **Recorded call -> shard set:** `ports/tyger-student/live_shard.py --log call.jsonl
  --out bench-results/live-call-shards` writes `data.py`'s shard format (via
  `data.save_shard`), so `gate.py`/`agreement.py` read the live events as their reference
  side. Add `--features <npz>` from `featurize.py --wavs <capture dir>` to fill `hu`/`ha`
  from the same call's audio and make the shard fully replayable (one call per log file
  for that join). `--selfcheck` pins the format.
- **What it is not:** the log's `teacher` array is the *live tier's* 8-vector, not the
  fp32 teacher's, and it records the deployed tier only — a shadowed call (two models
  over one mic) is still a separate instrument.

### Tap latency vs the windowed path (2026-11-05, #102)

**Verdict first: the 560 ms tap does not bust the +320 ms worst-session bar.** Paired
against today's windowed path on the same audio, its endpoint decisions arrive **+168 ms
mean-of-medians, +187 ms worst session** — but per *frame* the tap really is late (p95
518 ms, max 519 ms after that frame's audio), and 8 of 35 matched endpoints (23%) land
more than +320 ms later. The bar is a per-session median, so it passes; the tail is the
product risk, and a 320 ms chunk removes the phase error (below).

Why measure at all: today's path encodes an 8 s window per 320 ms hop and takes the last
4 rows, so a frame's feature exists at its hop's boundary. The ASR tap emits **7 frames
per 560 ms chunk at the chunk boundary**, so the first frame of a chunk waits up to
~0.5 s after its own audio. The endpoint bars are stated from audio availability, so this
was a kill risk until measured. Harness: `ports/tyger-student/tap_latency.py`
(`--selfcheck`; no threshold, rule or model change).

**Setup.** Three real call captures (the `live-shipping` sessions' audio, i.e. the
`TurnCapture` stereo wavs in `~/Library/Application Support/Idfon/turn-captures`):
`2026-10-25T23:13:14Z` (1394 frames / 199 chunks / 348 hops), `2026-10-26T20:17:43Z`
(1114 / 159 / 278), `2026-10-26T21:13:38Z` (1891 / 270 / 472). The `live-shipping`
shards have no wav beside them — the wav is the capture, and its frame count is cut to
the shard's `T` (the recording is a few frames longer). Three replays on one session
clock, same L4 student (`bench-results/student-l4-coreml/StudentStep.mlpackage`), same
rules (`idfon_voice_turn_*` from the app's dylib, per-frame `prev_state`, resets at
BARGE/ENDPOINT), mode `listen` on both sides (these shards have no mode track):

| replay | feature production | release |
| --- | --- | --- |
| `today` | Core ML L4 cut, 8 s (growing) window per 320 ms hop, both ears | hop boundary |
| `tap` | streaming tap artifact, one call per 560 ms chunk, both ears | chunk boundary |
| `cadence` | **the windowed features above**, no encode cost | chunk boundary |

`cadence` is the control that separates the batching from the feature change; it keeps
today's rows and rules, so its event sequence is asserted identical to `today`'s (the
assertion is in the harness). Encoder calls are timed with `perf_counter_ns` and composed
on a virtual audio clock (group start = max(group audio end, previous group's decision
end); no sleeping, no dropping). Rules events are paired same-kind within ±2 frames by
audio timestamp — the existing `gate.aligned_count` convention — never by arrival order.

**Frame grid.** The tap's 7 rows per chunk are shard **frames 7i+1 … 7i+7** (chunk 0 also
releases the reference grid's context row as frame 0; the ASR has no row 0). Measured
against the stored windowed rows, `tap[r]` matches `ref[r]` after that padding at cos p50
0.95 / p05 0.87, versus p05 0.17 and 0.28 at ±1 frame. The call is stamped 90 ms past the
chunk's last new mel frame — the mel window is 65 frames (56 new + 9 pre-encode context).
That gives the per-frame wait `490 − 80k` ms before inference, for `k = 0…6`.

**Feature ready − that frame's audio end (ms).** `today` is the shipped path's own
boundary wait; `tap` includes its inference.

| session | today p50 / p95 / max | tap p50 / p95 / max | tap max on real rows (frame ≥ 1) |
| --- | --- | --- | --- |
| 23:13:14Z | 165.9 / 257.1 / 328.7 | 278.3 / 518.4 / 588.3 | 519.2 |
| 20:17:43Z | 165.9 / 256.9 / 332.5 | 278.3 / 518.4 / 599.5 | 520.3 |
| 21:13:38Z | 165.9 / 256.9 / 329.1 | 278.2 / 518.3 / 587.4 | 518.6 |

The 588–600 ms maxima are frame 0, the chunk-0 context row (not a streaming row); the
tap's own worst row is 519 ms = 490 ms of cadence + 29 ms of inference. Inference is
23.6–27.8 ms per 560 ms chunk for both ears in this pass (the 42/13 artifact measures 9.6
ms/chunk/ear), and 14.7–17.4 ms per 320 ms hop today (the growing-window `dyn` model
costs up to 93 ms in the first 8 s, hence today's 329–333 ms max). This pass ran at host
load average ~10; an earlier pass measured 17.1 ms/chunk and the tap's own worst row at
508 ms, i.e. the extra is encode time, and the paired deltas moved by ≤ 7 ms.

**Paired endpoint decision delta vs `today` (ms).** Per event: `decision(tap) −
decision(today)`; per session: the median; aggregate: the gate's mean-of-per-session-
medians and worst session (no new percentile).

| session | matched ep | tap − today median | p95 | max | cadence − today median |
| --- | ---: | ---: | ---: | ---: | ---: |
| 23:13:14Z | 10 | 187.4 | 429.7 | 502.0 | 159.0 |
| 20:17:43Z | 12 | 147.0 | 506.0 | 511.7 | 118.5 |
| 21:13:38Z | 13 | 170.2 | 418.9 | 431.8 | 193.0 |
| **mean of medians** | 35 | **168.2** | — | — | **156.8** |
| **worst session** | | **187.4** | | | **193.0** |

Pooled over the 35 matched endpoints: median 182 ms, p95 501 ms, max 512 ms, and **8/35
(23%) above +320 ms**; 20/35 fire on the same frame on both paths (the other 15 shift
−2…+2 frames with the feature change, worth ±160 ms and included in the delta). The
control's agreement with the real tap delta (157 vs 168 mean) says the effect is the
cadence, not the 56/0-vs-windowed feature change. Unmatched endpoints (14 tap-only, 9
today-only over the three sessions) are the known feature/pass mismatch and are counted,
not averaged away.

**Backlog.** None accumulates: the tap's end-of-session lag is 17–28 ms (its per-chunk
cost is 4–5% of the 560 ms period), and at most one encode is ever outstanding. Today's
worst per-encode lag is 89–93 ms (the growing-window model in the first 8 s), also
with no growth.

**Against the bars.** Worst-session **+187 ms ≤ +320 ms — pass**. The mean-of-medians
+168 ms sits just over the gate's other latency bar (+160 ms mean-of-medians); that bar
is written against the teacher's latency, not against today's path, so treat +168 ms as
"at the bar" rather than a formal failure. The absolute per-frame number (p95 518 ms) is
real but is not what the endpoint gate scores — today's 320 ms hop already makes a frame
wait 0–240 ms.

**Would a smaller chunk recover it? Plausibly yes.** The wait scales with the chunk's
frame count: `560 ms chunk → 490 ms worst`, `320 ms (4 frames, today's lattice) → 250 ms`
and the 4-vs-7 phase error disappears (the residual is then the 90 ms pre-context plus
inference, ~+95 ms per event), `160 ms (2 frames) → 170 ms`. The 90 ms mel pre-context is
fixed geometry. That, plus the tail above, is the next decision — not
something this harness changes. The ASR's own decode and the #1109 callback are **not**
in these timestamps (the tap is read at the encoder call's return), and there is no
iPhone measurement yet.

**Artifact caveat.** The 42/13 artifact on disk predates the mask fix (2026-11-05), so
the tap replay uses a **reference-pass (56/0)** artifact exported for this measurement:
`export_asr_tap.py --export --pass reference --precision fp16 --int8` (594 MB). The
chunk cadence is the property under test, not the mask; the feature-level decision
agreement in the table is therefore not the product's 42/13 number.

Reproduce (artifacts are gitignored; paths are the maintainer layout):

```sh
ports/tyger-student/.venv/bin/python ports/tyger-student/export_asr_tap.py \
    --export --pass reference --precision fp16 --int8 --out bench-results/asr-tap
ports/tyger-student/.venv/bin/python ports/tyger-student/tap_latency.py \
    --verify --rules-dylib mac/Vendor/libiroh_c_ffi.dylib \
    --out bench-results/tap-latency.json
```

That harness stops at the encoder call's return. The section below closes it by
replaying the same captures through the real manager and timing the callback.

### Tap delivery through the real manager (2026-11-05, #132/#102)

**Verdict first: the callback path adds nothing measurable beyond the encoder return — the
whole manager, measured through `StreamingNemotronAsrManager` itself, lands +7.3 ms
mean-of-medians and +28.5 ms worst-session p95 against the offline stamp, and the RNNT
decode never delays the frame it is decoding.** The ~0.5 s per-frame wait is the 560 ms
chunk boundary, exactly as the offline harness said; what the earlier numbers did not
include was the manager around the encoder call, and that turns out to be ~7 ms of buffer
fill plus a 2-9 ms decode that runs *after* the tap is delivered.

Why this measurement exists: `tap_latency.py` stamps a frame's tap at the **encoder
call's return** on a virtual clock. The product does not read it there. It reads it from
the fork's `setEncoderOutputCallback` — which the manager fires inside `processChunk`
after `encoder.prediction` returns, before the decode loop — and the manager also owns
everything before that call: chunk accumulation from live capture buffers, the native
Swift mel front-end (`NemotronMelExtractor`), and, after the hook, the RNNT decode that is
serial on the same actor and could therefore delay the *next* chunk. Probe:
`tools/asr-tap-latency/` (standalone SwiftPM package, `swift run -c release`; app targets
untouched).

**Setup.** The shipping 560 ms model dir (`~/.idfon/models/nemotron-streaming/560ms`:
real `decoder`, `joint`, `decoder_joint`, `tokenizer.json`, `metadata.json`), with only
`encoder/encoder_int8.mlmodelc` replaced by the **corrected 42/13 int8 tap export**
(`bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage`, the post-mask-fix
one — not the 56/0 reference pass the offline harness needed). Fork pin
`donpark/FluidAudio@2ad9b422` (`encoder-output-callback`), `cpuAndNeuralEngine`, macOS
27.2 / M4 Pro / load average ~5. Same three captures and the same frame counts as the
offline run; the tap path is **mic channel only** (the manager is mono; the offline
harness encoded both ears, so it charged ~2x the encode time this path pays).

Replay is one `AsyncStream` producer → one serial `await manager.process(audioBuffer:)`
consumer — the app's shape. Two clocks: **paced** feeds each buffer when its own audio
would have arrived (682-frame buffers = the mic tap's 2048 @48 kHz; monotonic deadline,
spinning the last 1.5 ms), **unpaced** supplies everything at once so the same code
measures arithmetic only. Audio end of global frame *g* is `t0 + (g+1)·80 ms`; the probe
also records every callback's reported origin and frame range: the step is exactly 7
frames per chunk on all three sessions (`origin_step_ok`).

**Frame alignment was measured, not assumed.** A synthetic 3 s silence + 1 s noise burst
(`--onset`) put the onset at sample 48000 = frame 37: the first tap row whose direction
departs from the silence baseline is **row 37** (cos 0.47 vs 0.90 for row 36), i.e. row
*g* covers audio `[80g, 80(g+1))` — the same grid the offline harness used, whose `+90 ms`
pre-context stamp and `+1` frame index cancel. It also confirms the real path never waits
for audio past the chunk boundary: the 9 pre-context mel frames come from
`extractMelCache` of the *previous* chunk.

**Callback entry − that frame's audio end (ms), 682-frame buffers, paced.**

| session | frames | chunks | p50 / p95 / max | callback − chunk audio end p50 / p95 / max |
| --- | ---: | ---: | --- | --- |
| 23:13:14Z | 1393 | 199 | 281.5 / 528.2 / 545.1 | 41.5 / 61.5 / 65.1 |
| 20:17:43Z | 1113 | 159 | 281.0 / 528.2 / 546.2 | 41.0 / 62.3 / 66.2 |
| 21:13:38Z | 1890 | 270 | 281.5 / 527.6 / 545.7 | 41.5 / 61.2 / 65.7 |

Per row of a chunk (p50, identical across sessions): `k0 522 · k1 442 · k2 362 · k3 282 ·
k4 202 · k5 122 · k6 41` — i.e. `480 − 80k` of cadence plus ~41 ms of manager, so the
worst row waits **480 ms**, not the offline model's 490 (the manager releases at the chunk
boundary, not 90 ms past it).

**Where those 41 ms go** (all p50 unless noted): buffer fill ≤ one tap buffer (paced only;
with 320-frame buffers the same session measures 259.7 / 501.2 / 506.4 and a chunk lag of
19.7 — 21 ms less, i.e. half the slack) · `process` entry → hook = **19 ms** (resample +
native mel + encoder + the fork's cache/mel plumbing) · hook → `process` return = **8 ms**
(decode + state saves; the `decode` a token-emitting chunk actually spends after the hook
is 6.4 / 10.3 / 5.8 ms at p50, 10.6 / 15.0 / 15.8 at p95). Per chunk wall time unpaced is
**10-11 ms**, 2% of the 560 ms period: nothing accumulates (no dropped buffers in any run,
pending ≤ 0 at the end, chunk lag flat across all 270 chunks of the longest session).

**Is the callback itself costing anything?** Interleaved A/B in one process, same audio,
hook on/off ×3: 12.11 / 12.91 / 20.03 ms per chunk with the hook vs 11.91 / 15.81 / 13.66
without — **within run-to-run noise** (mean +1.2 ms, individual deltas −2.9…+6.4, host
load ~5). Structurally the fork gives it no room either: between `encoder.prediction`
returning and the hook there is no model call and no `await` — three cache lookups, a
9×128 mel-cache copy, a 7-entry dictionary. So the answer to "does the callback path add
latency beyond the encoder return" is **no: ≲ a few ms per chunk, ≤ 1% of the period, at
the edge of what this host can resolve** — and the decode, which the offline harness never
charged, lands *after* the tap has been handed over.

**Paired against the offline numbers** (same sessions, same frame grid, per frame
`measured − offline`): **+7.5 / +7.0 / +7.5 ms at p50, +27.7 / +28.5 / +27.2 at p95,
+31.1 / +32.2 / +31.7 at max**. Mean-of-medians **+7.3 ms**, worst session **+7.5 ms**.
That is the whole correction to the earlier table, and it is *net of* the cheaper encode
(one ear ≈ 9 ms vs both ears ≈ 24 ms), so the manager's own overhead — fill slack, mel,
plumbing, actor contention — is ~22 ms and largely cancels the encode it saves.

**Against the bars.** Delivery-level: mean-of-medians **+7.3 ms ≤ +160 ✓**; worst-session
median **+7.5 ms**, i.e. 187.4 + 7.5 = **+194.9 ms ≤ +320 ✓**. Endpoint-level (the bars are
written on endpoint decisions; this probe runs no rules or student, so the measured shift
is applied to the offline endpoint deltas — legitimate because the shift is near-uniform,
all 7 rows of a chunk move together): mean-of-medians **+175.5 ms** vs the +160 bar — still
over by 15.5 ms, exactly as the offline +168 was already over; worst session **+194.9 ms**
vs +320 ✓. The literal per-session p95 reading is unchanged too: offline p95 429.7 / 506.0
/ 418.9 → ~+28 = 457.7 / 534.0 / 446.9, so the 23%-past-320 tail is a property of the
560 ms cadence, not of the manager.

**Packaging findings** (each blocks a real app swap; the probe's `stage_models.py` works
around them *without* touching the fork, the app or a weight):

1. **`prompt_id` is not in the English manager's contract.** The export declares six inputs
   (the multilingual contract); `StreamingNemotronAsrManager.processChunk` feeds five, and
   Core ML refuses: *"Feature prompt_id is required but not specified"*. The staged copy
   bakes `prompt_id = 101` into the MIL program as a const (`--verify`: bit-identical to
   the six-input artifact's own default). A shipping export needs five inputs.
2. **Cache depth must match the pass.** The 42/13 export declares
   `cache_channel [1,24,42,1024]`; the manager sizes caches from `metadata.json`, whose
   shipping value (70) is the 56/0 pass. The staged metadata says 42. Any swap has to ship
   the metadata with the artifact.
3. **`tapFrameOrigin` survives `reset()`** (only `cleanup()` clears it): origins 0 → 1400 →
   2520 across three `reset()`-separated sessions, step exactly 7. The app calls
   `manager.reset()` on every utterance commit, so a consumer must carry its own baseline
   origin or the fork should reset it with the rest of the session state.

**What this does not measure.** iPhone ANE scheduling and thermals (this is an M4 Pro with
the shipping decoder; the encode is ~9 ms/chunk here and the phone is unmeasured) · the
rules/student/endpoint path (moved by a uniform shift, not re-run) · the 42/13-vs-56/0
feature-level decision difference (that is the refit's number, not this one).

Reproduce (artifacts gitignored):

```sh
tools/asr-tap-latency/run.sh          # stage + onset + unpaced + paced + 2 controls
ports/tyger-student/.venv/bin/python tools/asr-tap-latency/summarize.py \
    bench-results/asr-manager-probe/paced.json
```

### Per-frame tap scoring (2026-11-05, #132)

**Verdict first: per-frame scoring does not bring the endpoint delta under the +160 ms
bar — it already was the published +168. Scored per frame at delivery, the delta is
+166.6 ms mean-of-medians (+173.9 through the manager's measured shift), worst session
+179.9, 8/35 endpoints (23%) past +320. The number a 4-frame hop would give is +300.4 /
+459.5 / 46%; per-frame recovers that 134 ms and halves the tail, but the residual is the
560 ms chunk *delivery*, not hop buffering.**

The question assumed the existing tap replay was scored on the shipped 4-frame hop. It was
not: `tap_latency.py` already released every row of a chunk at its boundary and stepped it
immediately (`decide()`), so `--scoring per-frame` reproduces that pass row for row. The
new `tap-hop` mode is what routing tap rows through `TurnRuntime.feed` — the shipped
4-frame API — would cost, and that is the mode per-frame replaces.

**Why a 4-frame hop is not simply "320 ms more".** A hop is released when its last row is
delivered, and 4-frame hops do not align with 7-frame chunks: in every 28-frame period,
three hops straddle a chunk boundary and delay 3, 2 and 1 rows respectively. Six rows per
28 (21%) wait exactly one extra chunk; the rest are unaffected. Measured gap between
`tap-hop` and `per-frame` decision times: **559.0-559.8 ms on 17 of 105 events**, 0
elsewhere. That is 21% of frames delayed 560 ms, not every frame delayed up to 320 ms.

**Setup.** Same three `live-shipping` captures, same fp32 L4 student, same rules (mode
`listen`), both ears as before, reference-pass (56/0) tap artifact re-exported for this run
(`bench-results/asr-tap-ref56`, 594.1 MB; the windowed rows verify against the shards at
cos p50 0.99995 / relL2 0.0103). Rules events are identical in frame and kind across
`chunk`, all three `per-frame` policies and `tap-hop` — the comparison is pure decision
timing. The manager adds the #174 shift (+7.5 / +7.0 / +7.5 ms per-session p50), applied as
a uniform per-session shift, not re-measured here.

| session | frames | today ep | tap ev/ep | matched ep (same frame) | fp median | hop median | fp p95 | hop p95 | fp past +320 | hop past +320 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 23:13:14Z | 1394 | 14 | 34/15 | 10 (5) | 179.9 | 180.1 | 427.6 | 427.8 | 3/10 | 3/10 |
| 20:17:43Z | 1114 | 12 | 31/15 | 12 (5) | 140.0 | **459.5** | 499.4 | **739.4** | 3/12 | **7/12** |
| 21:13:38Z | 1891 | 18 | 40/19 | 13 (10) | 179.8 | 261.5 | 419.8 | 499.9 | 2/13 | **6/13** |
| **pooled / mean-of-medians** | | | | **35 (20)** | **166.6** | **300.4** | | | **8/35 (23%)** | **16/35 (46%)** |
| through the manager (+7.35) | | | | | 173.9 | 307.7 | | | | |
| worst-session median / p95 | | | | | 179.9 / 499.4 | **459.5 / 739.4** | | | | |

Endpoint counts match the earlier table exactly (35 matched, 20 on the same frame, 14
tap-only, 9 today-only; the event totals are 105 tap vs 95 today), and the pooled tail is
unchanged at 8/35; the 1.6 ms difference in mean-of-medians vs the published +168.2 is
this host's encode time. Frame-level feature delay is unchanged at p50 266.1 / p95 506.2
ms (tap rows exist only at the chunk boundary).
Backlog does not accumulate in any mode: max 18.0 / 23.3 / 17.9 ms, end 16.2 / 16.1 / 17.3.

**The three `left` policies are decision-identical, and that is the finding.** `left`
reaches only a BARGE's reported `onset_s` in the speaking branch
(`crates/idfon-voice/src/turns.rs`: `(talk_frames + left) * FRAME_S`, capped at
`ONSET_MAX_S`); the debounce itself (`yield_run >= barge_deb`) and every other decision
never read it. So on these listen-mode captures all three policies produce the same
events at the same frames and the same times (asserted in `assemble`). Measured, each
policy separately:

| policy | `left` at frame f | mean-of-medians | worst session | worst p95 | past +320 | events / endpoints |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `hop-phase` (today's value sequence) | `3 - f%4` | 166.6 | 179.9 | 499.4 | 8/35 | 105 / 49 |
| `zero` | 0 | 166.6 | 179.9 | 499.4 | 8/35 | 105 / 49 |
| `chunk-countdown` (the existing tap pass's value) | 7..0 in chunk 0, else 6..0 | 166.6 | 179.9 | 499.4 | 8/35 | 105 / 49 |

Onset semantics differ even though the numbers do not:

| policy | extra onset it claims | verdict |
| --- | --- | --- |
| `hop-phase` | 0-240 ms of hop audio already appended by `begin_hop` today | reproduces today's *onset numbers*; under per-frame `begin_hop` appends only this frame's audio, so those later frames have not been scored and the value is stale |
| `zero` | none | the only value consistent with a runtime that appends audio per frame; changes the reported onset by 0 to −240 ms vs today |
| `chunk-countdown` | 0-560 ms | worst of both: neither today's lattice nor the scored audio |

Which policy reproduces today's **decisions**: all three, exactly — so no policy can be
chosen on that basis. Which reproduces today's **onset duration**: `hop-phase` keeps the
arithmetic, `zero` keeps the audio timeline; per-frame scoring cannot have both, because
today's onset counts audio that the 4-frame hop had already fed to `begin_hop` and a
per-frame runtime has not. That is a rules-level decision (does the ENDPOINT/BARGE audio
buffer keep the hop's padding, or end at the scored frame?), not an instrumentation
choice, and this run does not make it. Consequence to settle before any swap: per-frame
scoring either keeps today's onset numbers but overstates speech by up to 240 ms, or
shortens the reported onset by the same amount.

**Barge evidence — none under per-frame scoring, and no claim.** The barge work that
exists is windowed-feature evidence: `bench-results/barge-live.md` replays these same
`TurnCapture` WAVs through the offline L4 student and measures yield-head crossings within
640 ms of an energy-VAD onset (`scripts/analyze-call-capture.py`); `barge-openyap.md` does
the same on Open Yap shards (`scripts/analyze-openyap-barge.py`). Neither runs the rules'
`onset_s`, neither has tap rows, and neither has a mode-`speaking` track, so neither can
test the `left` question. The live captures are `listen`-mode throughout. Per-frame
scoring's barge path is therefore **unmeasured**; the only claim made here is the code
fact that `left` cannot move a decision.

**Scope.** Mic and playback ears both stay as the harness has them (two tap artifacts,
two encoder calls per chunk); this tests the mic ear's scoring lattice, not the
playback-ear/cross-talk question. No threshold, model, app or fork change. The manager
contribution is its measured shift, not a scored replay inside the probe: that probe has
no student or rules and is mic-only, so scoring there would drop the agent ear.

Reproduce:

```sh
# reference-pass (56/0) tap artifact (the doc's cadence control; 594 MB, gitignored)
ports/tyger-student/.venv/bin/python ports/tyger-student/export_asr_tap.py \
    --export --pass reference --precision fp16 --int8 --out bench-results/asr-tap-ref56
ports/tyger-student/.venv/bin/python ports/tyger-student/tap_latency.py --verify \
    --tap-artifact bench-results/asr-tap-ref56/encoder_tap_fp16_int8w.mlpackage \
    --out bench-results/tap-latency-perframe.json
```

`--scoring chunk,per-frame,tap-hop` and `--left-policies hop-phase,zero,chunk-countdown`
select the modes; `--selfcheck` covers the left sequences and the chunk/hop grid.

### 320 ms chunk probe: latency first (2026-11-05, #132)

**Verdict first: a 320 ms chunk brings the endpoint delta under the +160 ms bar — +100.9 ms
mean-of-medians, +100.9 ms worst session, p95 +101.3 ms, 0/10 matched endpoints past +320
(the 560 ms tier: +173.9 / +179.9 / +499.4 / 23%). The tail is gone, but the tier is less
informative: the encoder sees 5 rows per chunk (1 context + 4 new) instead of 8 (1+7), so
the earliest kept row has 3 future rows (240 ms) instead of 6 (480 ms). The quality effect
is unquantified — no WER, pass gate, refit or decision-agreement table was run — so the
next decision is a quality gate, not a refit.**

Why the tier looked promising: at 560 ms the tap releases 7 rows at the chunk boundary and
a 320 ms decision hop is 4 rows, so the lattice cannot align (six rows per 28 wait one extra
chunk). At 320 ms a chunk is exactly 4 rows and the phase error disappears. This probe asks
only whether the latency is there.

**Artifact and geometry.** `bench-results/asr-tap-320ms/encoder_tap_42-13_320ms_fp16_int8w.mlpackage`,
**593,311,138 B**, **9.29 ms/chunk** on host ANE (one ear; the 560 ms form is 8.92). Two ears
are ~18.6 ms, 5.8% of the 320 ms period. Chunk mel 32 + 9 pre-context = 41 total, **4 rows
out**, cache depth **42** unchanged, pass **42/13** unchanged. The mask is still NeMo's block
mask: at T = 5 the 42/13 geometry gives every query all **47 keys** (42 cache + 5 current
rows), and the reference pass is still the 57-key sliding window; both are asserted in
`test_asr_tap_mask.py::test_320ms_tier_keeps_the_42_13_block_mask`, not derived from prose.
One implementation fact this tier forces: the conformer conv cache is 8 frames, so a chunk
shorter than 8 must carry the old cache's tail forward (`_conv`), not just its own rows.
The 56/0 torch selfcheck at 320 converges to cos p50 1.0 / min 0.99995 but max|d| 2.6e-1,
above the 2e-3 bar the 560 tier meets; the artifact's own int8 gate matches the 560 gate
(tap cos p50 0.981, encoded 0.957). The tier's feature fidelity is therefore near-exact but
not bit-exact, and it is not a substitute for a quality gate.

**Metadata.** The sidecar the manager reads now says `chunk_mel_frames` **32**, `chunk_ms`
**320**, `pre_encode_cache` 9, `total_mel_frames` **41**, `cache_channel_shape`
**[1,24,42,1024]**, `cache_time_shape` [1,24,1024,8], so `chunkSamples = 32 * 160 = 5120`.
The earlier 70-vs-42 mismatch was **`cache_channel_shape[2]`** (the base 56/0 bundle's 70
shipped beside a 42-deep artifact); here it is derived from the artifact's declared input
and confirmed to be 42 by the staging script.

**Latency replay, one session** (`2026-10-26T20:17:43Z`, the same captures/student/rules and
per-frame lattice as the published 560 ms run; `tap_latency.py`):

| tap tier | matched ep | endpoint median | p95 | max | past +320 | backlog max / end | tap events / ep |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 560 ms (re-run here) | 12 | 141.8 | 501.6 | 501.6 | 3/12 (25%) | 19.1 / 18.3 ms | 31 / 15 |
| **320 ms** | **10** | **100.9** | **101.3** | **101.4** | **0/10** | **18.1 / 17.9 ms** | **30 / 14** |

The 560 ms re-run reproduces the published row (140.0 / 499.4 / 3/12), so the harness change
is not the effect. Feature delay on the 320 ms tap is p50 186.3 / p95 267.6 ms (real rows:
147.2 / 267.6 / 268.1 max) versus 560's 268.1 / 508.2; today's windowed path is unchanged.
The deltas cluster at ~101 ms because the 320 ms chunk and the 4-frame hop now share a phase;
the residual is the fixed 90 ms mel pre-context plus encode. One matched endpoint lands
−218.7 ms (the tap earlier than today); the other nine are +100.5…+101.4 ms. Unmatched
endpoints are counted, not averaged away (tap-only 4, today-only 2 for endpoints).

**Real manager at this tier.** It loads without a code change once the tier's metadata and
the baked `prompt_id` are staged (`stage_models.py`): the manager sizes caches and chunk
buffers from `metadata.json`, and `tapFrameOrigin` advanced exactly 4 frames per chunk over
278 chunks. Paced on the device clock, the callback's per-frame delay is **p50 154.4 / p95
286.9 / max 295.8 ms** versus the 560 ms staged model's **281.0 / 528.2 / 546.2 ms** (chunk
lag 34.1 / 53.2 / 55.8 vs 41.0 / 62.3 / 66.2), and `measured − offline` is +0.1 ms p50 /
+19.3 ms p95. Sanity transcript through the shipping English decoder on the same capture:
320 ms "Call that a, a''', a''s a ''s a ''s a" (26 tokens) vs 560 ms "Course, the snow.
S'' a. S. A''s, I'll have a ''ha" (32 tokens) — comparable on this capture (both poor; it is
not the reference decoder for this audio), which is the check that the tier is not broken,
not a quality result.

**What this does not measure, and the stop.** The information loss is real and unquantified:
the 320 ms chunk sees at most 4 new rows of future context (3 after the earliest kept row)
instead of 7 (6), and no decision-agreement, WER or adapter refit was run. If a quality gate
later shows the tier is acceptable, the refit target moves from 42/13-at-560 taps to
42/13-at-320 taps; until then the 560 ms artifact and its published numbers stay
authoritative, and nothing in the shipping path or the frozen migration contract changes.

Reproduce (artifacts are gitignored):

```sh
ports/tyger-student/.venv/bin/python ports/tyger-student/export_asr_tap.py \
    --export --pass shipping --chunk-ms 320 --precision fp16 --int8 \
    --out bench-results/asr-tap-320ms
ports/tyger-student/.venv/bin/python ports/tyger-student/tap_latency.py \
    --sessions 2026-10-26T20:17:43Z --scoring per-frame --left-policies zero \
    --tap-artifact bench-results/asr-tap-320ms/encoder_tap_42-13_320ms_fp16_int8w.mlpackage \
    --out bench-results/tap-latency-320ms.json
ports/tyger-student/.venv/bin/python tools/asr-tap-latency/stage_models.py \
    --tap bench-results/asr-tap-320ms/encoder_tap_42-13_320ms_fp16_int8w.mlpackage \
    --out bench-results/asr-manager-probe/models/320ms --verify
tools/asr-tap-latency/.build/release/asr-tap-latency \
    --models bench-results/asr-manager-probe/models/320ms --chunk-frames 4 \
    --sessions 2026-10-26T20:17:43Z:1114 --modes paced
```

### The 320 ms tier's decision cost (2026-11-05, #132)

**Verdict first: the 320 ms tier is not decision-neutral, and it does not fire earlier —
it churns and skews late. With the deployed `l4-streaming` adapter and the frozen corpus
calibration, 86.1% of events survive a ±2-frame same-kind match between 560-artifact and
320-artifact taps (272/316; 81.6% at T=1, the uncalibrated table convention). That is a
12.9 pt miss of the 99% interchangeability bar for a 0.6% median cosine drift per frame
(0.9937) — the tier's perturbation is small but lands where the endpoint decision lives. Teacher event agreement falls 3.0 pts (60.76% → 57.73%), the product bars barely
move, and the swap is therefore a product call, not a free latency win. No refit was run;
the cost of one is at the end.**

Direction is the part a single agreement number would hide. At the frozen calibration,
of 202 endpoints matched within ±10 frames: **34 fire earlier, 129 on the same frame, 39
later**; 28 of the 215 560-endpoints have no 320 counterpart inside ±2 frames and 22 320
endpoints are new at that tolerance. Fifteen of the 28 losses come back as 3–10-frame
(240–800 ms) shifts in the wider match, so they are moved, not vanished; **13 are gone at
±10**. That is churn plus a late skew, not a systematic early cut — which matters because
an early-firing tier that loses correct endpoints would be a different (and worse) answer.

**What was featurized, and the frame grid (measured, not assumed).** The 320 artifact was
re-exported with the same command as the latency probe (the earlier `asr-tap-320ms/` path
was gitignored and did not survive): **593,311,138 B**, chunk mel 32 + 9 context → 4 kept
rows per call, cache 42, pass 42/13. Eight val sessions through the artifact, both ears,
`--frames 2248` — the same 8 sessions and frame counts as `tap-shipping-fixed/artifact`
(24.0 min audio, 17,984 frame-pairs per ear). Featurization is through the artifact as
served (int8 weights + fp16 compute), not a torch simulation.

The tier changes how many rows one encoder call releases, so the grid was established
before any comparison:

| lag (rows) | −2 | −1 | **0** | +1 | +2 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `hu` cos p50 / p05 | 0.945 / 0.180 | 0.964 / 0.321 | **0.994 / 0.958** | 0.971 / 0.322 | 0.957 / 0.180 |
| `ha` cos p50 / p05 | 0.890 / 0.158 | 0.936 / 0.304 | **0.994 / 0.959** | 0.940 / 0.304 | 0.893 / 0.158 |

Lag 0 wins by 4.5 cos points at p05 and loses 0.6 at p50, so an 80 ms slip would show.
Two further checks: the 560 side re-emitted through the same path is **bit-identical** to
the stored `tap-shipping-fixed/artifact` shards (`max|d| = 0.0`), and every label,
`teacher`, `energy`, `prev_state` and event array is `np.array_equal` between the 320 and
560 shard sets. Per-session drift (320 vs 560): `hu` cos p50 0.9889–0.9983, `ha`
0.9898–0.9972 — no session is a sick outlier.

**Same-adapter decision comparison (`tap_gate.py`, ±2 frames, same-kind, carried state).**

| configuration | events | aligned | A↔B | teacher A (560) → B (320) |
| --- | ---: | ---: | ---: | --- |
| refit adapter, T=1 (uncalibrated) | 293 | 239 | **81.57%** | 59.22% (183/309) → 57.10% (177/310) |
| **refit adapter, frozen corpus (T=.9, ep .90)** | 316 | 272 | **86.08%** | **60.76% (192/316) → 57.73% (183/317)** |
| pre-refit adapter, T=1 (fitted on 56/0) | 285 | 226 | **79.30%** | 59.87% (182/304) → 54.13% (164/303) |

Controls on the same 8 sessions, same checkpoint, to place those numbers:

| comparison | what differs | aligned | A↔B |
| --- | --- | ---: | ---: |
| 560 artifact ↔ itself | nothing | 290/290 | **100.00%** |
| fp32 ↔ int8 artifact | weight grid only | 262/295 | **88.81%** |
| 56/0 shards ↔ 560 artifact | the pass (published row) | 235/301 | **78.07%** |

The tier (86.08%) sits between weight quantization (88.81%) and the pass swap (78.07%),
and it does so with *less* feature drift than quantization (cos p50 0.9937 vs 0.9826) —
decision agreement is not monotone in cosine, which is why the direction table below, not
the aggregate, carries the finding. The calibration choice moves the pair by
4.5 pts, so one policy per domain (the frozen contract) stays mandatory.

**Per kind and direction** (refit adapter; `only_A` = the 560 side fires it and the 320
side does not, `only_B` = the 320 side adds one; "agree" is per-kind aligned ÷ max(A,B)):

| kind | calibration | A | B | aligned | only_A | only_B | B earlier / same / later | agree | ±10 recovered (earlier/same/later) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| ENDPOINT | frozen | 215 | 209 | 187 | 28 | 22 | 25 / 129 / 33 | 87.0% | +15 (34/129/39) |
| BACKCHANNEL | frozen | 97 | 96 | 85 | 12 | 11 | 4 / 73 / 8 | 87.6% | +7 (7/73/12) |
| ENDPOINT | T=1 | 193 | 194 | 154 | 39 | 40 | 19 / 103 / 32 | 79.4% | +31 (31/103/51) |
| BACKCHANNEL | T=1 | 97 | 97 | 85 | 12 | 12 | 4 / 73 / 8 | 87.6% | +5 (8/73/9) |

**Teacher-relative product bars** (`harness.py`, 8 sessions, 44 eot, 1 onset, 375 bc;
`ep_lat_s` is the mean of per-session endpoint medians against the teacher's turn ends):

| feature source | ep_lat_s | early | miss | bc prec | bc rec |
| --- | ---: | ---: | ---: | ---: | ---: |
| teacher | 0.48 | 10 | 4 | 0.24 | 0.33 |
| 560, T=1 | 0.47 | 8 | 6 | 0.27 | 0.33 |
| 320, T=1 | 0.40 | 8 | **3** | 0.23 | **0.23** |
| 560, frozen corpus | 0.30 | 10 | 3 | 0.26 | 0.29 |
| 320, frozen corpus | 0.34 | **8** | 3 | 0.25 | 0.28 |

So the quality cost is not a cliff: at the frozen calibration the 320 tier fires two fewer
premature endpoints, misses the same number, loses one backchannel point, and its endpoint
median is +40 ms. The 10-pt backchannel-recall drop at T=1 is the one row where an
uncalibrated threshold punishes the tier, and the corpus fit absorbs it — another reason
the frozen policy is the one to quote.

Per session (refit adapter, frozen calibration; `tA/tB` are the teacher-event agreements):

| session | frames | A | B | aligned | only_A | only_B | agree | tA / tB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 14b6b0b1… | 2248 | 68 | 60 | 52 | 16 | 8 | 76.5% | 40 / 31 |
| 7e412007… | 2248 | 32 | 32 | 31 | 1 | 1 | 96.9% | 27 / 29 |
| 9d18c769… | 2248 | 57 | 58 | 54 | 3 | 4 | 93.1% | 45 / 44 |
| ab39a952… | 2248 | 25 | 25 | 24 | 1 | 1 | 96.0% | 10 / 10 |
| ba20e232… | 2248 | 30 | 30 | 23 | 7 | 7 | 76.7% | 19 / 18 |
| d0cabd7d… | 2248 | 50 | 49 | 42 | 8 | 7 | 84.0% | 25 / 26 |
| d622d1e3… | 2248 | 28 | 31 | 27 | 1 | 4 | 87.1% | 12 / 12 |
| f3ca6a93… | 2248 | 22 | 20 | 19 | 3 | 1 | 86.4% | 14 / 13 |

**What this does and does not decide.** It decides the question the latency probe left
open: the tier's information loss (3 future rows instead of 6, 240 ms instead of 480) moves
~14% of decisions and costs ~3 pts of teacher event agreement. It does not measure the
manager's delivery at this tier (already measured — +100.9 ms mean-of-medians, 0/10 past
+320) or WER, and it runs no training. No number here is a latency measurement; the
featurization ran on an M4 Pro at load average ~2–5, and every comparison is a content
comparison on the same 80 ms grid.

**If the latency win is worth paying for, this is the bill.** A refit would re-target the
adapter on 320-artifact taps with the committed recipe: 60 train + 8 val sessions
featurized through the 320 artifact (~10 min on this host), adapter-only on the frozen
trunk, 20 epochs (~16 min; the last refit's mtimes, 11:02 → 11:28, are the same shape),
then recalibrate and re-gate. No new data, no trunk fit, no QAT. It cannot close the 99%
A↔B gap — the features differ by construction, so a 320-trained adapter is a new decision
surface — and it must therefore be judged by teacher agreement and the product bars
against the 560 tier, not by interchangeability with it.

Reproduce (artifacts and shards are gitignored; the 560 artifact and shard sets are
untouched):

```sh
PY=ports/tyger-student/.venv/bin/python
MAIN=/Users/don/dev/idfon/bench-results
$PY ports/tyger-student/export_asr_tap.py --export --pass shipping --chunk-ms 320 \
    --precision fp16 --int8 --out bench-results/asr-tap-320
$PY ports/tyger-student/pass_gate.py --emit-shards bench-results/tap-shipping-320 \
    --pass shipping --chunk-ms 320 --split val --shards $MAIN/tap4-shards/val \
    --sessions 8 --frames 2248 \
    --artifact bench-results/asr-tap-320/encoder_tap_42-13_320ms_fp16_int8w.mlpackage
$PY ports/tyger-student/tap_gate.py --student $MAIN/shared-shipping-refit-fixed/student.pt \
    --tap l4-streaming --shards-a $MAIN/tap-shipping-fixed/artifact \
    --shards-b bench-results/tap-shipping-320 --per-kind --temp 0.9 --ep-thr 0.90
$PY ports/tyger-student/gate.py --shards bench-results/tap-shipping-320 \
    --student $MAIN/shared-shipping-refit-fixed/student.pt --tap l4-streaming --temp 0.9 --ep-thr 0.90
$PY ports/tyger-student/harness.py --shards bench-results/tap-shipping-320 \
    --student $MAIN/shared-shipping-refit-fixed/student.pt --tap l4-streaming --temp 0.9 --ep-thr 0.90
```

### Ruling: the split tier is what ships (2026-11-05, #132)

**Decided: turn path on the 320 ms prefix, ASR on NVIDIA's 560 ms full encoder.** The
320-only single-pass shape is deferred, not rejected — it needs a WER gate on an
off-spec tier and it re-couples the tap to the running ASR's invocation (the `#1109`
callback), neither of which the split tier needs.

| | value |
|---|---|
| graphs | 2: the 560 full encoder (ASR, unchanged) + a 102,003,481 B prefix (turns) |
| weights | 1 model; one tap definition (`hidden_states[4]`) |
| turn cadence | 320 ms, batched two ears in one call (bit-identical to two calls) |
| turn latency | +100.9 ms mean-of-medians, 0/10 endpoints past +320 |
| turn quality | product bars at parity with 560-deployed; teacher agreement −3.0 pts (inside noise); 19.1% of decisions move |
| assets | **701 MB** (594 + 102 + 5.28 step) replacing 983 MB — the 389 MB cut is gone, net **−282 MB** |
| duty | 2.6% of a 320 ms period, replacing 14.7–17.4 ms of windowed work |
| ASR | untouched: no WER risk, no partial-cadence change, NVIDIA's tier |

**What this amends on the epic.** The footprint condition becomes: delete the private
389 MB cut, replace the windowed re-encode with one batched prefix pass per 320 ms, and
keep the ASR on its own tier. That is **not** "one encoder invocation per period" — it is
one ASR pass plus one cheap turn pass — and `#1109` stops gating the turn path, because
the prefix is an artifact we own. Say it that way in the epic; the old wording is now
wrong rather than unmet.

**Wiring constraints already measured, not to be rediscovered:** feed both ears
continuously with silence for the inactive one and never reset per utterance (a cold
cache costs ~4 cos points for ~6 chunks, duplicates a frame, and `tapFrameOrigin`
survives `reset()`, drifting +1 frame per restart); batch both ears (bit-identical,
39% cheaper than two calls); `prompt_id` is not in the English manager's contract; and
`cache_channel` depth must come from the artifact (42), not the shipping metadata.

### The 320 refit and a turn-purpose prefix (2026-11-05, #132)

**Verdict first: the refit is a wash, not a rescue.** Re-targeting the `l4-streaming`
adapter on 320-tap features recovers **1.7 pts** of same-adapter tier stability
(86.08% → 87.78%) and nothing of the teacher-agreement gap: **57.78% vs the 320 tap's
57.73% before the refit, against 60.76% for the 560-deployed path** at the frozen corpus
policy. The product bars are within noise of both (early 10 vs 10, miss 3 vs 3,
bc recall .27 vs .29, endpoint median .35 vs .30 s). Swapping today's deployed 560 path
for 320+refit still moves **19.1% of decisions** (80.89% paired, ±2 frames, same kind) at
the frozen policy. **The 320 prefix is 102,003,481 B (17.2% of the 593 MB full pass) and
1.82 ms/chunk vs 8.09 on host ANE — bit-identical tap rows (max|d| 0.0) — but it cannot
produce `encoded`, so it is a turn-path-only artifact.**

Why the refit cannot close the gap is structural, not a training failure: adapter-only
training changes the decision surface even at *identical* features (the published 16.9 pt
adapter-transfer gap, `docs/voice-tyger-refit-42-13.md`), so a 320 refit is a *different*
surface from the deployed one by construction. The 99% A↔B bar was never the right bar
here; teacher agreement and the product bars are, and on those the tier's cost survives
the refit.

**Recipe (frozen, unchanged from the 560 refit).** Adapter-only on the frozen trunk:
`train_shared.py --adapter-only l4-streaming`, warm start `shared-consistent-l03`,
λ=0.3, `--weights auto`, seed 0, 20 epochs, window 250, lr 1e-3; features through the
320 artifact as served (fp16 compute + int8 weights), never a torch simulation. 60 train
+ 8 val sessions at 2248 frames (12 min on this host), 13 live captures (2.5 min), 20
epochs (9 min) — **≈26 min wall**, the bill the previous section estimated.

| check | result |
|---|---|
| frozen trunk / decoder / heads | **35 non-adapter tensors byte-identical** to `shared-consistent-l03`; the 4 `adapters.l4-streaming.*` tensors moved (adapter-only did what it says) |
| weighted loss | 0.16273 → 0.15997 (560 refit: 0.16205 → 0.15981 — same trajectory) |
| probe weights (auto) | state 1.268 / hazard .906 / barge .683 / bc .853 / endpoint 1.289 — the 560 fit is 1.266 / .911 / .684 / .851 / 1.288, i.e. **the tier does not move the P0 weight basis** |
| val score gates (320 tap) | state .00765, hazard .00433, barge .00249, bc .00513, **endpoint .02680 ≤ .028**, hold AUC .886 (report-only) — all pass; the 560 refit reads .00774 / .00416 / .00234 / .00511 / .02639 |
| step export | 5.28 MB fp32, parity max|d| 1.64e-06, 0 flips, 0.047 ms/step; int8 step still 1.27e-2 (FAIL, out of scope as before) |

**Judged on the right bars** (8 val sessions, 2248 frames, both ears; ±2-frame same-kind):

| corpus path | policy | teacher agreement |
| --- | --- | ---: |
| 560 deployed (560 tap) | frozen T=.9 / ep .90 | **60.76%** (192/316) |
| **320 refit (320 tap)** | frozen T=.9 / ep .90 | **57.78%** (182/315) |
| 320 refit, fresh corpus fit | T=1.0 / ep .9146 | 58.17% (178/306) |
| 320 un-refit adapter (#180) | frozen T=.9 / ep .90 | 57.73% (183/317) |

| domain | deployed 560 path | 320 refit | fit |
| --- | ---: | ---: | --- |
| corpus (8) | 60.76% (192/316) | 57.78% (182/315) | frozen T=.9 / ep .90 (the 320 refit's own corpus fit lands at T=1.0 / ep .9146 / bc .5) |
| live (13) | 58.82% (260/442) | **59.27%** (259/437) | live T=.8 / ep .90 / barge .5 / bc .3 (deployed live fit: T=.8 / ep .88) |

Per-domain fits are one policy each, as the contract requires. The corpus fit and the
frozen policy are reported as two rows on purpose: the frozen policy is the like-for-like
comparator to the deployed path; the fresh fit is what a re-calibration would ship, and
choosing it *because* it scores better is exactly what the frozen contract forbids.

**Same adapter, both tiers (refit checkpoint, `tap_gate.py --per-kind`).** The refit's own
tier sensitivity, to be compared with 86.08% for the un-refit adapter:

| kind | 560 (A) | 320 (B) | aligned | only_A | only_B | B earlier/same/later | agree | ±10 recovered |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| ENDPOINT | 214 | 213 | 191 | 23 | 22 | 28 / 139 / 24 | 89.3% | +18 (36/139/34) |
| BACKCHANNEL | 95 | 91 | 82 | 13 | 9 | 5 / 75 / 2 | 86.3% | +4 (7/75/4) |
| **all** | 309 | 304 | **273** | 36 | 31 | — | **87.78%** | — |

Feature drift is unchanged from #180 (cos p50 0.9937 / p05 0.9586): the features did not
move, only the mapping did.

**The swap as it would ship (`cross_gate.py`, deployed 560 vs 320-refit, frozen policy).**
This is the number a product decision needs — both features and adapter differ:

| kind | 560 deployed (A) | 320 refit (B) | aligned | only_A | only_B | B earlier/same/later | agree | ±10 recovered |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| ENDPOINT | 215 | 213 | 179 | 36 | 34 | 25 / 132 / 22 | 83.3% | +24 (34/132/37) → **12 gone at ±10** |
| BACKCHANNEL | 97 | 91 | 75 | 22 | 16 | 5 / 65 / 5 | 77.3% | +10 (9/65/11) |
| **all** | 312 | 304 | **254** | 58 | 50 | — | **80.89%** | — |

So a 320 swap is *churnier* than the same-adapter tier effect (19.1% vs 12.2% of the
refit's decisions move): the tier accounts for ~12 pts and the **refit itself for the
other ~7** — the adapter-transfer gap showing up again, not a tier artefact.

**Product bars** (`harness.py`, 8 sessions, 44 eot, 1 onset, 375 bc; `ep_lat_s` = mean of
per-session endpoint medians against the teacher's turn ends):

| feature source | ep_lat_s | early | miss | bc prec | bc rec |
| --- | ---: | ---: | ---: | ---: | ---: |
| teacher | 0.48 | 10 | 4 | 0.24 | 0.33 |
| 560 deployed, frozen | **0.30** | **10** | **3** | **0.26** | **0.29** |
| **320 refit, frozen** | **0.35** | **10** | **3** | **0.23** | **0.27** |
| 320 refit, fresh corpus fit | 0.39 | 9 | 3 | 0.22 | 0.25 |
| 320 un-refit, frozen (#180) | 0.34 | 8 | 3 | 0.25 | 0.28 |

**Not worse than 560-deployed?** On the endpoint bars yes — same early count, same miss
count, +50 ms median; on backchannels no — recall −2 pts and precision −3 pts. Latency is
the tier's, not the adapter's: **+100.9 ms mean-of-medians / +100.9 worst / 0-of-10 past
+320** (560: +173.9 / +179.9 / 23%), measured before any refit and unchanged by it — the
student step is the same 5.28 MB, 0.047 ms/step model. Nothing here is WER: the ASR
stays at 560 in this shape.

**The prefix: layers 0–3, `tap_l4` only.** `hidden_states[4]` is the output of layers 0–3,
so a 4-layer export emits the same rows as the full model's `tap_l4` — measured, not
assumed:

| artifact | bytes | host ANE ms/chunk | outputs |
| --- | ---: | ---: | --- |
| `asr-tap-320/encoder_tap_42-13_320ms_fp16_int8w` | 593,311,138 | 8.09–8.11 | encoded, tap_l4, caches, encoded_length |
| **`asr-prefix-320/encoder_prefix4_42-13_320ms_fp16_int8w`** | **102,003,481** (17.2%) | **1.82** (22.5%) | **tap_l4, caches only** |

Parity over all 565 chunks of one 2248-frame val session, both graphs on host ANE:
**cos p50 1.00000000, p05 0.99999992, min 0.99999976, max|d| 0.0, mean|d| 0.0** (steady
and cold-start alike). Bit-identical is the expected result — the prefix *is* layers 0–3 of
the same int8/fp16 graph — and it is why every decision number above transfers to the
prefix unchanged. **A prefix cannot produce `encoded`**: the prompt projector, the last 20
layers and the decoder context are not in it, so it cannot transcribe and must never be
loaded as the ASR. It is a turn-path artifact, and it exists only because the ASR stays at
560 — if the ASR itself ran at 320 its own tap would already be these rows.

**The shape, if this ships.** Assets: the 560 ASR full pass (**594 MB**, unchanged) + the
320 turn prefix (**102 MB**) + the unchanged 5.28 MB student step = **~701 MB**, i.e.
+102 MB over today, and the 320 full-pass artifact is not shipped at all. Per 320 ms
period the host pays two prefix passes (mic + playback ear, 2 × 1.82 = **3.64 ms**) plus
the 560 ASR pass amortized (8.1 ms × 320/560 = **4.62 ms**) = **8.3 ms, 2.6% duty**;
today's shape pays that ASR pass plus a private windowed cut at 14.7–17.4 ms per 320 ms
hop for both ears, so the prefix *replaces* the cut and is ~12 ms cheaper per hop. Turn
latency is the tier's **+100.9 ms** mean-of-medians (0/10 past +320). What changes in the
frozen contract: (1) the encoder artifact row gains a prefix and the *turn* tier becomes
320 while the ASR stays 560 — the first split-tier row the contract has ever had; (2) the
tap is no longer the running ASR's own output but a **bit-exact 320 replica** of what a
320 ASR would emit, so the primary latency bar (+173.9 → +100.9, 23% → 0 of 10) is met
while the tier's decision churn (19.1% vs the deployed surface) is the price; (3) the
duplicate-pass precondition is satisfied *differently* — one ASR pass per hop, plus a
cheap turn pass, not the upstream `#1109` output callback, so that blocker stops gating a
320 turn path but the epic's "no second encoder pass" wording needs restating as "no
second *full* pass"; (4) calibration, rules, thresholds, app and fork are unchanged, and
the 99% interchangeability bar still does not apply (the rows differ by construction).

**What this does not establish.** No held-out set (the 8 corpus sessions and 13 live
captures are development data), no barge/overlap challenge set, no iPhone number, no
prefix memory measurement on device, and no WER question — the ASR is untouched. The
refit's corpus gain is inside the noise of 1–2 events, so "not worse" here means "not
measurably better either".

Reproduce (all artifacts and shards are gitignored; the 560 and 320 artifact and shard
sets are read-only inputs and are never overwritten):

```sh
PY=ports/tyger-student/.venv/bin/python
MAIN=/Users/don/dev/idfon/bench-results
A320=$MAIN/asr-tap-320/encoder_tap_42-13_320ms_fp16_int8w.mlpackage

# 1. features through the 320 artifact (60 train + 8 val; val is copied, not re-emitted)
$PY ports/tyger-student/pass_gate.py --emit-shards $MAIN/tap-shipping-320-refit/train \
    --pass shipping --chunk-ms 320 --split train --shards $MAIN/tap4-shards/train \
    --sessions 60 --frames 2248 --wav-cache $MAIN/asr-tap/wav --artifact $A320
cp $MAIN/tap-shipping-320/*.npz $MAIN/tap-shipping-320-refit/val/
$PY ports/tyger-student/featurize_live_artifact.py \
    --wavs "$HOME/Library/Application Support/Idfon/turn-captures" \
    --shards $MAIN/live-shards-l4-all --out $MAIN/live-shipping-320 \
    --chunk-ms 320 --artifact $A320

# 2. the refit (adapter-only, frozen trunk) and its fits
$PY ports/tyger-student/train_shared.py --tap l15-windowed=$MAIN/student-shards \
    --tap l4-windowed=$MAIN/l4-shards --tap l4-streaming=$MAIN/tap-shipping-320-refit \
    --init $MAIN/shared-consistent-l03/student.pt --adapter-only l4-streaming --weights auto \
    --consistency 0.3 --seed 0 --epochs 20 --lr 1e-3 --window 250 \
    --deploy-tap l4-streaming --out $MAIN/shared-shipping-320-refit
$PY ports/tyger-student/calibrate.py --shards $MAIN/tap-shipping-320-refit/val \
    --student $MAIN/shared-shipping-320-refit/student.pt --tap l4-streaming \
    --temp-grid 0.8,0.9,1.0,1.1,1.25 --out $MAIN/shared-shipping-320-refit/corpus.traits.json
$PY ports/tyger-student/calibrate.py --shards $MAIN/live-shipping-320 \
    --student $MAIN/shared-shipping-320-refit/student.pt --tap l4-streaming \
    --temp-grid 0.8,0.9,1.0,1.1,1.25 --out $MAIN/shared-shipping-320-refit/live.traits.json

# 3. the bars: teacher (gate), product (harness), tier (tap_gate), swap (cross_gate)
$PY ports/tyger-student/gate.py --shards $MAIN/tap-shipping-320-refit/val \
    --student $MAIN/shared-shipping-320-refit/student.pt --tap l4-streaming --temp 0.9 --ep-thr 0.90
$PY ports/tyger-student/harness.py --shards $MAIN/tap-shipping-320-refit/val \
    --student $MAIN/shared-shipping-320-refit/student.pt --tap l4-streaming --temp 0.9 --ep-thr 0.90
$PY ports/tyger-student/tap_gate.py --student $MAIN/shared-shipping-320-refit/student.pt \
    --tap l4-streaming --shards-a $MAIN/tap-shipping-fixed/artifact \
    --shards-b $MAIN/tap-shipping-320-refit/val --per-kind --temp 0.9 --ep-thr 0.90
$PY ports/tyger-student/cross_gate.py \
    --a-student $MAIN/shared-shipping-refit-fixed/student.pt --a-shards $MAIN/tap-shipping-fixed/artifact \
    --b-student $MAIN/shared-shipping-320-refit/student.pt --b-shards $MAIN/tap-shipping-320-refit/val \
    --tap l4-streaming --temp 0.9 --ep-thr 0.90 --per-kind

# 4. the turn prefix and its parity
$PY ports/tyger-student/export_asr_tap.py --export --pass shipping --chunk-ms 320 \
    --precision fp16 --int8 --prefix-only --depth 4 --out $MAIN/asr-prefix-320
$PY ports/tyger-student/export_asr_tap.py \
    --gate $MAIN/asr-prefix-320/encoder_prefix4_42-13_320ms_fp16_int8w.mlpackage --gate-full $A320 \
    --pass shipping --chunk-ms 320 --prefix-only --depth 4 \
    --session-id d622d1e377001bba8c718a2fbdac0b7b --wav-cache $MAIN/asr-tap/wav \
    --json $MAIN/asr-prefix-320/parity.json
```

### The playback ear: `ha` from the same encoder (2026-11-05, #132/#102)

**Verdict first: yes — the playback ear can move off the cut at the same fidelity as the
mic ear, for one more 8 ms chunk and ~6 MiB, provided the stream is fed continuously and
not reset per utterance.** Paired against the stored windowed cut rows the playback tap
lands at **cos p50 0.943–0.951 / p05 0.860–0.866, rel-L2 p50 0.31–0.34** — the same band
as the mic ear re-run in the same pass (0.950–0.956 / 0.868–0.876, 0.30–0.32). One loaded
artifact with two independent cache sets costs **8.2 ms per ear per 560 ms chunk** (two
streams 16.2–16.6 ms; +7 turn steps = **17.0 ms, 3% of the period**) and **+6.1 MiB**
RSS for the second set (56/0; +4.7 MiB at 42/13). The residual risk is not fidelity or
compute, it is the **restart**: a cold stream is ~4 cosine points off for ~6 chunks, emits
one duplicated frame per restart, and (fork bug) keeps climbing frame origins.

Why this was the last unmeasured piece: today `TurnRuntime.feed` encodes **both** ears
through the private L4 cut every 320 ms hop, so deleting the cut needs `hu` *and* `ha`
moved. The mic ear had been measured; the playback channel (the agent's own TTS voice) had
not, and it needs its own encoder cache because the two streams start, run and stop
independently. Harness: `ports/tyger-student/playback_ear.py` (`--selfcheck`).

**Setup.** The same three `live-shipping` captures and frame counts as the sections
above, playback channel (channel 1 of the `TurnCapture` stereo WAV); the reference is the
**stored** `ha_l4`/`hu_l4` from `bench-results/live-shipping`, so the tap rows are compared
against the exact cut rows the other work used, not a re-run. A replay of the windowed cut
reproduces those rows at cos 0.99993–0.99995 (label: re-run). Two artifacts:

| key | artifact | pass | cache depth |
| --- | --- | --- | ---: |
| reference | `bench-results/asr-tap-ref56/encoder_tap_fp16_int8w.mlpackage` | 56/0, the published per-frame numbers' artifact | 56 |
| shipping | `bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage` | corrected 42/13, the shipping-intended export | 42 |

Grid: tap stream row *i* is chunk `i//7`, row `i%7`, and reproduces stored cut row `i+1`
(the mic channel's measured offset). The offset-0 control at p50 is weak on *both*
channels (playback 0.908–0.931 vs 0.943–0.951 at +1; mic 0.857–0.894 vs 0.950–0.956)
because neighbouring 80 ms steps of the same speech are similar — the sharp evidence is
the earlier p05 test (0.87 at +1 vs 0.17 at 0) and the onset probe, and the playback ear
uses the same grid. Per chunk position the parity is flat (`k0…k6` 0.93–0.95 at 56/0), so
no row of a chunk is the weak one.

**Feature parity per frame, tap vs the stored cut rows** (frames 1…T−1):

| session | frames | playback cos p50 / p05 | rel-L2 p50 | mic re-run cos p50 / p05 | rel-L2 p50 |
| --- | ---: | --- | ---: | --- | ---: |
| 23:13:14Z | 1394 | 0.9427 / 0.8661 | 0.340 | 0.9556 / 0.8755 | 0.298 |
| 20:17:43Z | 1114 | 0.9512 / 0.8602 | 0.313 | 0.9549 / 0.8684 | 0.300 |
| 21:13:38Z | 1891 | 0.9509 / 0.8649 | 0.315 | 0.9497 / 0.8726 | 0.317 |
| *42/13:* 23:13:14Z | 1394 | 0.9320 / 0.8532 | 0.370 | 0.9420 / 0.8620 | 0.342 |
| *42/13:* 20:17:43Z | 1114 | 0.9383 / 0.8386 | 0.353 | 0.9419 / 0.8561 | 0.340 |
| *42/13:* 21:13:38Z | 1891 | 0.9363 / 0.8433 | 0.358 | 0.9372 / 0.8578 | 0.355 |

The playback ear sits within **1.3 cosine points** of the mic ear and within **0.04
rel-L2** (in either direction) in the same run — it is not a special case. The 42/13 pass
costs ~1.1–1.5 points on both ears, as the 42/13-vs-56/0 feature difference already
implied; the refit target stays the 42/13 taps.

**Cost: one stream vs two, one loaded artifact** (per 560 ms chunk, 199/159/270 chunks):

| session | one stream p50 / p95 | two streams p50 / p95 | step p50 | encode + 7 steps | share of 560 ms |
| --- | --- | --- | ---: | ---: | ---: |
| 23:13:14Z | 8.23 / 8.50 | 16.49 / 17.35 | 0.07 | 17.01 | 3.0% |
| 20:17:43Z | 8.20 / 8.44 | 16.46 / 16.86 | 0.07 | 16.98 | 3.0% |
| 21:13:38Z | 8.27 / 9.11 | 16.57 / 16.91 | 0.08 | 17.09 | 3.1% |

(42/13 is the same shape, 0.3 ms faster: one 8.07–8.12, two 16.22–16.28, budget 16.8 ms.)
The second stream is additive, as expected: one ANE job at a time, the two calls are
serial in the same artifact. **There is no per-cache-set compute cost** — the cost is the
second encode — and the turn steps are 0.5 ms per chunk, i.e. noise next to it.

**Resident memory, one vs two cache sets.** The tap caches are I/O tensors, so a second
ear is a second tuple, not a second model: `cache_channel` 24×56×1024 fp32 = 5.25 MiB
plus `cache_time` 0.75 MiB = **6.00 MiB per ear** at 56/0 (**4.69 MiB** at 42/13). Measured in
a **fresh child process** (load the artifact, one ear live for two calls, `ps -o rss`, then
the second ear live): **+6.1 MiB** at 56/0, **+4.7 MiB** at 42/13 — the analytic size. This
is macOS RSS on an M4 Pro and **not an iPhone number**; the phone is unmeasured. For
comparison, a second in-process `MLModel` on the same package adds only 13–18 MiB here
(the weights are the same mapped file) — the reason to prefer one artifact with two cache
sets is the ~8 ms/chunk of RNNT decode a second *manager* would run for an ear that needs
no text, not the weights.

**`ha` availability, reported apart from the mic ear** (ms after that frame's audio end):

| session | today (hop end + hu encode + ha encode) p50 / p95 / max | streaming (chunk end + hu + ha) p50 / p95 / max |
| --- | --- | --- |
| 23:13:14Z | 160.1 / 246.7 / 314.4 | 266.5 / 506.6 / 511.7 |
| 20:17:43Z | 159.8 / 246.6 / 313.7 | 266.5 / 506.5 / 506.9 |
| 21:13:38Z | 159.6 / 246.4 / 313.4 | 266.3 / 506.4 / 507.9 |

The playback ear does not have its own latency story: today it is encoded *after* the mic
ear in the same hop (3.1–3.2 ms p50, up to 37 ms while the 8 s window is still growing),
and in the streaming shape it is encoded after the mic ear in the same chunk. So `ha` is
never earlier than `hu` on either path, and the streaming `ha` inherits the same chunk
cadence the mic ear already measured (the +266/506 numbers are that cadence plus the
second encode). No separate bottleneck, and no separate fix.

**Failure mode: restarting the playback stream at utterance starts.** The capture's
agent channel is active 24–31% of the session with 13/14/17 utterance starts after ≥1 s
of silence, so restarts are the normal case. Restarting a cold stream (fresh caches, no
pre-context) and comparing its rows with the continuous stream at the same audio frames:

| session | restarts | cos vs continuous, chunk 0 / 1 / 3 / 6 / 7 | duplicate rows | origin drift, continuous feed |
| --- | ---: | --- | ---: | ---: |
| 23:13:14Z | 13 | 0.905 / 0.951 / 0.952 / 0.968 / 0.989 | 13 | +12 frames (0.96 s) |
| 20:17:43Z | 14 | 0.911 / 0.953 / 0.956 / 0.982 / 0.992 | 14 | +13 frames (1.04 s) |
| 21:13:38Z | 17 | 0.910 / 0.943 / 0.953 / 0.977 / 0.992 | 17 | +16 frames (1.28 s) |

Three distinct failures, all real:

1. **Stale (cold) cache — bounded.** The first chunk of a restart is ~4 cosine points
   below the continuous stream (0.905–0.911 vs ~0.95) and is back to steady by chunk 6–7
   (~3.4 s). The restarted stream's chunk 0 has no 9-frame pre-context, and the 56-deep
   cache needs ~6 chunks to fill; silence alone does **not** do this (parity right after a
   ≥1 s gap in the continuous stream is 0.943 / 0.953 / 0.954 vs 0.942 / 0.950 / 0.949
   steady).
2. **Duplicated frames — structural.** A restarted chunk 0 releases 8 rows: the context
   row is emitted once as frame `g0` and again as frame `g0+1`. One per restart, always,
   and it is the *cold* row — its cosine to its own neighbour is 0.37 when the restart
   lands in silence (zero pre-context) and 0.95 mid-speech.
3. **Frame-origin drift — the wiring bug.** `tapFrameOrigin` survives `reset()` in the
   fork (0 → 1400 → 2520, #174), so a consumer must rebase per stream start. Even with
   silence fed continuously, the extra context row per restart advances the origin by 8
   rows per 7 frames of audio: **+1 frame per restart, cumulative** (+16 frames = 1.28 s
   by the end of the longest session). If playback audio is only fed while the agent is
   playing, the skipped silence is lost from the origin on top of that (−837 / −803 /
   −1483 frames at the last restart), i.e. rows land tens of seconds early.

**Design decision.** Shipping-intended shape measured here: **one loaded artifact, one
cache set per ear, both streams fed continuously (silence included), no reset**, with the
playback ear read by a direct encoder call (its own caches, no RNNT decode). Why: it is
the shape today's windowed path already has (`TurnRuntime` appends both hops every 320 ms
regardless of who is talking), it sidesteps all three restart failures, and it costs
8.2 ms + 6 MiB. Resetting per utterance is the *power-saving* shape and is not free: it
needs its own origin baseline and accepts ~6 chunks of cold cache, so it is a separate
decision, not a drop-in.

**What this does not measure.** iPhone ANE scheduling, thermals and RSS (M4 Pro numbers
above) · the fork's API for a second stream (the hook is per-manager; a direct encoder
call is the shape that was costed, a second manager is not) · the 42/13-vs-56/0 effect on
*decisions* (that is the refit's number) · barge/overlap (unchanged: these captures are
`listen` throughout) · whether the app should feed silence when playback is idle (product
wiring). No threshold, model, app or fork change.

Reproduce:

```sh
ports/tyger-student/.venv/bin/python ports/tyger-student/playback_ear.py --selfcheck
ports/tyger-student/.venv/bin/python ports/tyger-student/playback_ear.py \
    --out bench-results/playback-ear.json
```

`--artifacts reference-56-0,shipping-42-13` selects the exports; `--limit-frames` is a
debug aid; the RSS delta is re-measured in a child process because freed pages never
return to the parent.

### Batched ears and the silent-ear cache on the 320 ms prefix (2026-11-05, #132/#102)

**Verdict first: batching is exact — per-ear tap rows are bit-identical (cos 1.0,
max|d| 0.0) between one 2-slot call and two un-batched calls, in fp32 and in the
shipping fp16/int8w form. The silent-ear cache is *not* valid in a streaming pass as
stated: digital silence is not a fixed point until the prefix has run ~41 chunks
(13.1 s) of continuous silence. Reusing chunk 1's cache when speech returns lands at
cos 0.871 / rel-L2 0.51 against a continuously-fed stream — a shortcut that changes
features. From that fixed point onward reuse is bit-exact, but reaching it costs more
than the pauses it would save.**

Why this was worth measuring: tyger-s2s's ears engine stops the encode at L15 with a
forward hook, batches equal-length windows, and caches an all-zero window once per
length (`asr.py:15,27-32,65-68`, `constants.py: L15`). Our shape is different in the
one way that matters for the third trick: a **streaming prefix** carries a cache across
chunks, so an all-zero window is not a stateless re-encode. Harness:
`ports/tyger-student/batched_ears.py` (`--selfcheck`); export path is
`export_asr_tap.py --prefix-only --batch N --depth 4 --chunk-ms 320 --pass shipping`.

**The prefix artifact.** Layers 0–3 with `tap_l4` as the only value output; no
`encoded`, no prompt projector, and caches only for the layers that exist
(`[B,4,42,1024]` channel, `[B,4,1024,8]` time) because layers 4–23 cannot change the
tap. `--batch 2` makes those `[2,4,…]`; each slot threads its own cache — the second
slot is not a copy of the first. No 0–3 artifact from the sibling refit work existed
when this started, so this run exported its own pair; the truncation itself is exact,
not approximate (torch prefix vs the full 24-layer graph, `max|d| 0.0`). The full
encoder batched is also supported by the same flag, but is not what this study costs.

| artifact (320 ms, 42/13, `bench-results/asr-prefix-320/`) | bytes |
| --- | ---: |
| `encoder_tap_42-13_320ms_fp16_int8w_l4b1.mlpackage` | 102,004,689 |
| `encoder_tap_42-13_320ms_fp16_int8w_l4b2.mlpackage` | 102,003,748 |
| `encoder_tap_42-13_320ms_fp32_l4b1.mlpackage` | 406,314,835 |
| `encoder_tap_42-13_320ms_fp32_l4b2.mlpackage` | 406,313,894 |
| *shipping 24-layer full encoder, for scale* | 593,446,155 |

The b2 file is 941 B smaller than b1: the weights dominate and are shared, so two
ears in one file costs nothing in footprint. Per-ear cache memory is **0.78 MiB**
(4 × 42 × 1024 fp32 + 4 × 1024 × 8 fp32), not the 4.7 MiB of a 24-layer cache set.

**Batching equality: per ear, per chunk, one 2-slot call vs two un-batched calls.**
Both ears are different real audio (the runtime fixture and a live capture's agent
channel); caches start at the manager's `cache_len = 1` and are threaded for 12 chunks.
The table is the shipping int8w artifact with ANE; the fp32 pair and the torch wrapper
pair give the same result, and fp32's worst row is identical.

| chunk | ear A cos | A max\|d\| | ear B cos | B max\|d\| |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 1 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 2 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 3 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 4 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 5 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 6 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 7 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 8 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 9 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 10 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |
| 11 | 1.000000000 | 0.0 | 1.000000000 | 0.0 |

Worst over the whole run: **cos 1.0 / max|d| 0.0, bitwise equal** — true for fp32
(406 MB pair) and for fp16/int8w (102 MB pair), and for the torch batch-2 wrapper vs
two batch-1 wrappers. A batched graph that differed numerically would not be a win;
this one does not differ.

**Silent-ear cache: the streaming pass does not have the windowed pass's property.**
Feed the prefix the same constant digital-silence mel every chunk (a constant input is
the strongest case for reuse) and compare each chunk's released tap rows and caches
with the fixed point reached at chunk 79:

| chunk | tap cos vs final | tap max\|d\| | tap rel-L2 | cache-channel cos vs final |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 0.80943156 | 33.03 | 0.625 | 0.278 |
| 1 | 0.85692240 | 25.19 | 0.539 | 0.413 |
| 2 | 0.86139491 | 27.75 | 0.530 | 0.516 |
| 4 | 0.86945684 | 29.25 | 0.513 | 0.680 |
| 8 | 0.87098708 | 29.81 | 0.510 | 0.906 |
| 12 | 0.96191708 | 12.19 | 0.277 | 0.944 |
| 16 | 0.98236545 | 7.375 | 0.189 | 0.980 |
| 20 | 0.99637815 | 3.125 | 0.085 | 0.994 |
| 24 | 0.99920869 | 1.438 | 0.040 | 0.999 |
| 28 | 0.99991604 | 0.4375 | 0.013 | 0.9999 |
| 32 | 0.99999599 | 0.125 | 0.0028 | 0.999997 |
| 36 | 0.99999987 | 0.0625 | 0.0005 | 1.000000 |
| 40 | 0.99999999 | 0.0156 | 0.00015 | 1.000000 |
| 41 | 1.00000000 | 0.0 | 0.0 | 1.000000 |

The answers to the three questions:

- **(a) Tap rows are not identical across chunks.** They drift for 41 chunks. The
  per-chunk change is already small by chunk 7 (cos to previous 0.9999) but the
  absolute error against the fixed point is still ~30 at chunk 8 — cosine hides it.
  The `cache_len` saturates at 42 on chunk 8; that is not the settling time.
- **(b) The caches converge, but slowly and asymptotically.** The time cache settles
  first (chunk 40 to 2e-3), the channel cache at chunk 34; both are still moving at
  chunk 24 (channel cos 0.999, max|d| 0.047). The deep-layer attention/conv stack is
  an IIR, so a cold-start transient has a long tail even after the mask stops widening.
- **(c) Reusing chunk 1 is invalid.** Holding chunk 1's cache through the silent
  middle and then feeding speech gives **cos 0.871 / max|d| 21.5 / rel-L2 0.51**
  against feeding every silent chunk (int8w). The chunk-1 cache is 0.41 cosine to the
  fixed-point channel cache — half the feature vector's magnitude is wrong. Reusing
  from the fixed point is valid: at chunk 41 the held cache gives a **bit-identical**
  speech tap (fp32 control: 9.4e-5 max|d| from chunk 37).

So the honest form of the trick is: *you may reuse the silent-ear result only after
~37–41 chunks of continuous digital silence, and then only because the cache has reached
a true fixed point.* You have already paid the encoder for all of those chunks, and any
real near-silence (mic noise, playback residual, a non-zero mel floor) is not a fixed
point at all. It is not a per-length shortcut and it does not help ordinary pauses.

The fp32 export on CPU reproduces the same shape (stable at chunk 37, cos 0.9999 at
chunk 29, bitwise at 41; reactivation from chunk 1 cos 0.872, from chunk 37 cos 1.0 /
9.4e-5). The effect is semantic, not a quantization artefact.

**Cost per 320 ms period** (Mac M4 Pro, 64 GB; Core ML `CPU_AND_NE`; median of 50
calls after 5 warm; load average 3.5, 3.0–4.6 across three repeats; another process may
share the ANE):

| shape | p50 ms / period | duty |
| --- | ---: | ---: |
| two separate un-batched predictions | 3.63 | **1.14%** |
| one batched prediction (2 slots) | 2.22 | **0.69%** |
| batched shape, other ear silent (one un-batched prediction) | 1.84 | **0.58%** |
| CPU control, same three shapes | 7.90 / 4.72 / 3.93 | 2.47% / 1.48% / 1.23% |

Batching saves 1.41 ms per period (1.63× over two calls) for 941 B of artifact; it is
1.21× a single call, i.e. the second slot is nearly free because the 4-layer graph is
latency-floor-bound. The "silent-ear shortcut" is just the one-call row, because a
fixed-shape B=2 graph cannot skip a slot; if *both* ears are silent the honest cost is
0 (no call), which needs no cache trick. An earlier pass at load ~4 measured
2.4/2.8 ms instead of 1.8/2.2; the ratios held (1.8× vs 1.63×), so treat the absolute
milliseconds as contention-affected and the duty ordering as the result.

**What an iPhone number requires.** These are host numbers, not device numbers. A
device claim needs the same two artifacts run on an iPhone through Core ML (ANE) at
the 320 ms cadence with the 24-layer ASR manager resident, reporting per-call p50/p95,
ANE contention with the ASR pass, RSS and energy/thermals. A simulator is not a number;
the 102 MB file is the whole two-ear artifact, so the device question is compute and
scheduling, not download size. Nothing here changes a threshold, a rule, the app or
the fork.

Reproduce:

```sh
ports/tyger-student/.venv/bin/python ports/tyger-student/export_asr_tap.py \
    --export --prefix-only --batch 1 --depth 4 --chunk-ms 320 --pass shipping \
    --precision fp16 --int8 --out bench-results/asr-prefix-320
# repeat with --batch 2 (and --precision fp32 for the control pair)
ports/tyger-student/.venv/bin/python ports/tyger-student/batched_ears.py --selfcheck
ports/tyger-student/.venv/bin/python ports/tyger-student/batched_ears.py \
    --equality --torch --silence --cost --chunks 12 --silent-chunks 80 --units ane \
    --out bench-results/asr-prefix-320/study.json
```

### Barge on the live captures: mode fixed, measured for the first time (2026-11-05, #132/#102)

**Verdict first: the captures do contain real agent-over-caller speech, but only 12 of
the rules' 57 BARGEs land while the agent is still audible.** With `mode` correct, the
rules fire BARGE in 12 of the 13 capture files; 6 files (5 distinct conversations) have
a barge whose agent hop was loud, and 11 of those 12 had the caller voiced at the
crossing. The other 45 fire in the derived mode's 1.92 s release tail, after the agent
channel has gone silent — a mode-proxy artifact, not evidence of an interrupt. The claim
this unblocks is therefore narrow: **barge exists and is detectable on real calls, on
audio all 13 captures genuinely contain**; it is not yet an acceptance-grade barge set.

**Setup.** The 13 `TurnCapture` stereo wavs behind `bench-results/live-shipping`
(16 kHz, `ch0` = caller mic, `ch1` = playback). Three pairs share a caller-mic track
(`ch0` bit-identical: 04:50/05:26, 04:55/05:31, 05:07/05:42) while `ch1` differs
slightly, so the set is **10 distinct caller-mic tracks**. `TurnCapture`'s sidecar (`agentNonSilent`/
`agentPeak`) is **absent for all 13** — the field postdates these captures — so agent
activity was measured directly from `ch1`, which is stronger than the sidecar: all 13
have non-silent agent audio (92-777 frames above -50 dB), and none is a "silent `ch1` =
no barge evidence" capture. Thresholds are the frozen live contract
(ep .88 / barge .5 / bc .3); `barge_thr` is .5 in the teacher's defaults too, so this
choice does not move the barge count.

**One mode derivation.** `ports/tyger-student/mode_track.py` is now the only place a
replay decides `mode`: a shard/log `mode` track when present, otherwise the agent
channel's energy. It groups 80 ms frames into the 320 ms hops the app updates `mode` on
(`VoiceAgentSession` → `TurnShadow.setMode`), treats a hop as loud when any of its four
frames is above the rules' own voiced threshold **-50 dB**, latches `speaking`, and
releases after 6 quiet hops (1.92 s) to bridge pauses inside one agent turn. Nothing is
fitted on barge outcomes. `featurize.py` now uses the same function, so corpus shards and
replays cannot drift; any other string than `listen`/`speaking` (notably the old
`"response"`) is rejected.

**Instrument.** `ports/tyger-student/live_barge.py` (`--selfcheck`) replays each shard's
recorded live-tier 8-vector through the rules with that mode track, splits BARGEs by
whether the agent's hop was loud at the crossing, and writes
`bench-results/live-barge.json`. A per-frame alignment pin asserts the shard's `energy`
is this wav's `ch0` (max diff 0 in all 13).

| capture | s | agent loud | speaking | inaudible speaking | caller over agent | BARGE | stretches | audible hop | audible frame | onset p50/max |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2026-10-25T22:26:49Z | 128 | 496 | 676 | 165 | 49 | 1 | 1 | 1 | 1 | 2.32/2.32s |
| 2026-10-25T23:13:14Z | 112 | 344 | 632 | 278 | 148 | 11 | 4 | 3 | 2 | 0.32/1.76s |
| 2026-10-26T03:18:47Z | 77 | 92 | 236 | 139 | 53 | 4 | 2 | 1 | 0 | 1.28/1.28s |
| 2026-10-26T20:17:43Z | 89 | 344 | 620 | 266 | 84 | 0 | 0 | 0 | 0 | - |
| 2026-10-26T21:13:38Z | 151 | 453 | 911 | 443 | 105 | 4 | 2 | 0 | 0 | - |
| 2026-10-26T21:26:00Z | 180 | 697 | 1020 | 295 | 121 | 2 | 1 | 0 | 0 | - |
| 2026-10-27T04:50:44Z | 173 | 572 | 1112 | 525 | 85 | 9 | 4 | 0 | 0 | - |
| 2026-10-27T04:55:51Z | 183 | 349 | 860 | 490 | 126 | 5 | 4 | 1 | 1 | 0.96/0.96s |
| 2026-10-27T05:02:05Z | 180 | 777 | 1160 | 350 | 90 | 1 | 1 | 0 | 0 | - |
| 2026-10-27T05:07:33Z | 179 | 587 | 864 | 247 | 19 | 4 | 2 | 3 | 1 | 0.56/0.56s |
| 2026-10-27T05:26:30Z | 173 | 572 | 1116 | 529 | 85 | 10 | 4 | 0 | 0 | - |
| 2026-10-27T05:31:25Z | 183 | 200 | 544 | 329 | 88 | 2 | 2 | 0 | 0 | - |
| 2026-10-27T05:42:29Z | 179 | 587 | 872 | 255 | 19 | 4 | 2 | 3 | 1 | 0.56/0.56s |

`agent loud` = frames with `ch1` above -50 dB; `speaking` = derived mode frames;
`inaudible speaking` = derived speaking frames with `ch1` <= -60 dB (the release tail);
`caller over agent` = both channels above -50 dB in the same 80 ms frame; `audible hop` =
BARGEs whose 320 ms hop still had agent audio; `audible frame` = BARGEs with `ch1` above
-50 dB at the exact crossing frame; `stretches` = speaking runs containing at least one
BARGE (one interruption per agent stretch — the app switches floor on the first one);
`onset p50/max` is over `audible hop` events.

**What the numbers say.**

- **Overlap is real and present in every capture**: 1072 frames (85.8 s) of simultaneous
  caller + agent voicing, 19-174 frames per file. It is not playback leaking into the
  mic: the best normalized sample correlation between `ch0` and `ch1` over ±100 ms on
  loud 1 s blocks is **0.209**, and the frame-envelope correlation
  is ≈0, so the overlap is independent caller speech, not a delayed copy of `ch1`.
- **BARGE exists once mode is right**: 57 events, 12/13 files, 29 speaking stretches.
  Before the fix every harness passed `"response"`, so this count was structurally 0.
- **The audible subset is 12 events in 6 files / 5 distinct conversations**, with the
  agent hop loud at the crossing; 11/12 had the caller voiced at the event frame, and
  the sixth file's event (`03:18:47`, caller -56.5 dB) is a yield-head fire during a
  pause, not a mode error. Six events in 5 files still had `ch1` above -50 dB at the
  exact 80 ms frame. Onset distribution: **12 audible-hop events, p50 0.56 s, p95 2.01 s,
  max 2.32 s**; all 57 events p50 0.96 s, p95 2.51 s, max 3.20 s.
- **The 20:17:43 session has no BARGE despite 344 loud agent frames and 84 overlap
  frames** — a real overlap the yield head did not cross at .5 (the false-negative side,
  not "no overlap").
- **The 45 non-audible firings are the false-positive side of the proxy**: 4311 of the
  10,623 derived speaking frames (40.6%) have `ch1` <= -60 dB. Those frames sit in the
  1.92 s release tail, where the app may already be back in `listen`; the yield head
  fires late on a caller who is still talking. Counting them as interrupts would inflate
  the barge rate by ~4.75×.

**Sensitivity (derivation only, same rules thresholds).** `release 0` is the strict
proxy — speaking only on a loud hop — and `release 6` is the app-like latch. `release 2`
and `6` are identical here. The audible count is the stable number; the total is not.

| mode threshold | BARGE (release 0) | audible hop (release 0) | BARGE (release 6) | audible hop (release 6) |
|---:|---:|---:|---:|---:|
| -60 dB | 15 | 12 | 57 | 12 |
| -55 dB | 12 | 12 | 57 | 12 |
| **-50 dB (rules' VAD)** | **12** | **12** | **57** | **12** |
| -45 dB | 12 | 12 | 57 | 12 |
| -40 dB | 8 | 8 | 57 | 12 |

A barge number that depended on the mode threshold would not be evidence; the audible
set does not move between -60 and -45 dB, and only the tail count moves with the release.
The `-40 dB` row loses four audible events because hops whose only loud frame is in
[-50, -40) are no longer `speaking` at `release 0` — an artifact of conflating the mode
threshold with the audibility check, not a different barge picture.

**Controls (assert-based, `live_barge.py --selfcheck`).** A synthetic speaking-mode
replay whose yield head fires emits BARGE (positive); the same frames in `listen` mode
emit none (negative). `mode_track.py --selfcheck` pins the latch (a single loud frame
holds speaking for exactly 28 frames, then releases), the recorded-track pass-through,
and rejects `"response"`.

**Parity harnesses.** Every fixed call site now derives one mode array from the session
audio and feeds that same per-hop value to both compared sides (`parity5`, `parity6`,
`parity7`, `l15_tap`), so a parity result cannot become a comparison of two floors. A
fresh `l15_tap` run on one 2-min dualturn session measured 1499 frames and **25/32
events aligned (78.1%)**, feature cos 0.867 (mic) / 0.883 (agent) — the same band as the
published 74.2% on two 3-min sessions. The feature/tap axis is mode-independent (mode
never enters the tensor math), and the decision axis now runs both sides under one track.
`parity6`/`parity7` (Core ML) and `parity5` (MLX) were not re-run here because those
runtimes are not installed on this machine; their code change is the same shared-value
pass, nothing else. Shards that predate the mode track keep their listen-mode reference
events: `analyze-openyap-barge.py` now **withholds** event agreement for them rather than
compare a speaking replay against a listen replay; its yield-catch axis is mode-independent
and still reported.

**What the derivation cannot know.** The real floor is app-supplied; this is a proxy.
Playback that was scheduled but did not reach the speaker still reads as `speaking` (the
capture stores the playback bus, not the room), and agent audio leaking into the mic
would make caller frames look voiced — measured absent here (max corr 0.209) but not
guaranteed on other hardware. The 1.92 s release is the trainer's pause bridge, not an
app turn boundary, which is exactly why the tail count is reported separately and not
called barges. Finally, the 8-vectors are the recorded live tier's, so these are the
shipped head's decisions, not a student-vs-teacher comparison.

### The duplicate-pass precondition

The epic's footprint bar is that turn decisions cost **no second encoder pass**. Nothing
in this phase can establish that, and the matrix does not claim it. Before any swap-over
ships:

1. The deployed adapter must read the **streaming (cache-aware) tap** of the ASR that is
   actually running — `l4-streaming`, trained on `featurize_tap.py`'s stream pass, whose
   frame grid was verified equal to the windowed reference (offset 0/0, tail trimmed).
   A windowed re-encode (`l4-windowed`) is a different adapter with its own fit.
2. The ASR's own encoder must **expose** the tap (encoder re-export with a declared tap
   output + FluidAudio #1109's output callback). Until then the shipped tier carries the
   private L4 cut and pays the duplicate pass; the numbers above are the step only
   (1.75 MB, ≈0.2–1.0 ms/frame on a Mac), and the epic's bar stays **unmet**.
3. A per-hop runtime timeline must show **one** encoder invocation per ASR hop. TurnShadow
   is shadow-side evidence about the step, not proof about the encoder.
4. Traits travel with the step: the fitted temperature + threshold triple per adapter
   (`<adapter>/traits.json` here, `student-l4.traits.json` in the live bundle) ships
   beside the artifact. The fits here are corpus fits; the live triple is fitted on call
   captures, and a training change requires a re-fit (`calibrate.py --temp-grid`).

### Migration contract, frozen 2026-11-05 (#132 last mile)

Everything below is frozen before any further fit, so a result cannot be improved by
later choosing a different comparator, policy or data split. Changing any line is a
decision, recorded in #132, not a detail.

| item | frozen value |
|---|---|
| encoder artifact | `bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage`, **593,446,155 B**, 8.92 ms/chunk on host ANE (re-exported 2026-11-05; the pre-fix artifact is kept as `asr-tap-defect-mask/` for comparison and must not be quoted) |
| pass | NVIDIA 42 left / 13 lookahead / 42-deep cache, int8 weights. The reference pass (56/0) stays the **incumbent comparator**, not the target |
| student step | **fp32, 5.28 MB**, export parity 2.59e-06 against the 2e-3 envelope. Student int8 is out of scope here (1.07e-2, needs QAT) |
| calibration | **one** policy per domain, fitted once and then frozen: corpus T=0.9, live T=1.0 / ep .88 / barge .5 / bc .3 (from the corrected-feature refit). No retrospective "corpus vs live" choice per score |
| decision lattice | **per-frame**, one student step per 80 ms tap row. Routing rows through `TurnRuntime.feed`'s 4-frame hop measured +300 ms mean-of-medians, so it is excluded by evidence, not taste |
| `left` | `0` — `left` only extrapolates a barge's reported `onset_s` (`rules.py:121`); all three candidate policies are decision-identical, and `0` is the only one consistent with the audio timeline |
| latency bars | unchanged: mean-of-medians ≤ +160 ms, worst-session ≤ +320 ms. Measured at NVIDIA's 560 ms tier: **+173.9 / +179.9**, 23% of endpoints past +320 ms — the bar is **missed**, and that is the open product call |
| acceptance data | the 8 corpus sessions and the 13 live captures have now been used for fitting, calibration and bar recuts, so they are **development data** whatever their split name. Any acceptance claim needs sessions none of this touched |
| barge | **measured 2026-11-05** with `mode` derived from `ch1` (`mode_track.py`, -50 dB, 6-hop release) and the recorded live-tier 8-vector: 57 BARGEs in 12/13 capture files, of which **12 in 6 files / 5 distinct conversations land while the agent hop is still loud** (11/12 with the caller voiced at the crossing); 45 fire in the mode release tail and are not interrupts. All 13 captures carry 1072 frames of real caller-over-agent voicing (max echo corr 0.209), so the 20:17:43 zero is a miss, not no overlap. Not an acceptance set: no held-out labels, and the app's true floor is the proxy's unknown. See § "Barge on the live captures" |

What is still required before a swap can be judged: a held-out live set, a barge/overlap
challenge set with both positive and negative cases, playback-ear parity (in flight), and
the iPhone two-stream/backlog check. Nothing in the contract above substitutes for those.

### Negative results and stated skips (this phase)

- **Core ML int8 is not deployable** at 5.5e-3…1.4e-2 (see above). The layout cannot
  express the asymmetric per-output-unit grid; shipping int8 there needs a QAT run on
  Core ML's symmetric per-block grid — a training change, not a repack.
- **Core AI int8 is not covered**: `coreai_opt.quantization` (torchao PT2E) exists in the
  installed toolchain, but wiring it through `export_to_coreai` + the AOT compiler + the
  runtime gate is its own task; the Core AI rows are fp32, its shipping form.
- **The parakeet adapter row is not covered**: `parakeet-l12-full` lives in a different
  checkpoint (`shared-parakeet*`) and has no QAT fit. It joins the matrix the same way
  any new ASR does — `train_shared.py --adapter-only TAP`, `calibrate.py --tap`, then
  `--shards TAP=<tap-shards>`.
- **Every latency number is a macOS-host step measurement.** Cost is 0.04–1.0 ms/frame
  depending on tier; the 80 ms frame leaves two orders of headroom everywhere. No iOS
  device number exists yet, and the Core AI device path is blocked by #110.
- **AOT recompile cost**: each adapter's `coreai-fp32` export produced its own AOT
  container (the 3 exports are per-adapter artifacts, not one bundle).

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
