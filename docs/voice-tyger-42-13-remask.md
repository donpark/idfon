# 42/13 re-measurement after the mask fix (#102)

Status: **measured** (2026-11-05, second pass). The 42/13 shipping pass in
`docs/voice-tyger-streaming-plan.md` § Leg 1 and `docs/voice-tyger-refit-42-13.md`
was produced by a wrapper whose mask contradicted its own docstring: at cache 42
every query saw **43** keys (a causal sliding window), so the 13-frame lookahead
did nothing. Bounds are now per query (`asr_tap.py`, `PassConfig` docstring); the
reference pass is bit-unchanged, so every 56/0 number stands. **Every 42/13
number in the merged docs is void and is re-measured here.** The tables in those
docs are left as they were written, with a dated pointer added to this file.

Masks are now asserted directly (`test_asr_tap_mask.py`) rather than only stated
in a docstring — that is the process fix for how this defect survived.

## 1. What was verified before spending on exports

| check | result |
| --- | --- |
| reference 56/0 mask, full cache (`cache_len=56`) | **57 keys/query**, contiguous `[qi, 56+qi]` |
| shipping 42/13 mask, full cache (`cache_len=42`) | **50 keys/query**, every query sees keys `0..49` |
| lookahead is real at 42/13 | query 0 reaches key 49, i.e. 7 keys past its own position; the old causal clamp reached only `qi` |
| lookahead 0 reduces to the old formula | `torch.equal` at `cache_len` 1 / 7 / 14 / 55 / 56 |
| partial cache | shipping: 9 / 22 / 36 / 50 keys at `cache_len` 1 / 14 / 28 / 42; reference: 2…9 keys at `cache_len=1` |
| reference `--selfcheck` (wrapper vs HF, 20 s fixture) | **3.529e-05** by chunks 32–35, PASS — identical to the pre-fix value, so the reference pass is bit-unchanged |
| Core ML trace with the two new float buffers (`query_lo`, `query_hi`) | **succeeded** — fp16 + int8 weights, no `aten::Int` / int64-fold failure; only the usual int64→int32 save warnings |

`$PY ports/tyger-student/test_asr_tap_mask.py` (unittest, no model weights needed)
is the standing check; `key_mask()` was split out of `_attention` so the geometry
can be asserted without an 0.6B model.

## 2. The re-exported artifact

| | defective build | corrected build |
| --- | ---: | ---: |
| bytes | 593,446,722 | **593,446,155** |
| ANE ms/chunk | 9.62 | **8.92** |
| CPU ms/chunk | 20.40 | 22.98 |
| `model.mlmodel` sha256 | `6e64c128…e12833` | `0d73cd5c…36fc5d` |

Timing note: the 8.92 ms ANE figure was taken at load average ≈ 5.2 on a 14-core
machine (other work in the tree); the 9.62 ms figure was taken under its own,
unrecorded load. Treat the two as the same class (≈9 ms), not as a 0.7 ms win.

**The mask change is in the graph, not just in the metadata.** Both artifacts were
streamed over the same 96 s session (CPU_AND_NE) and compared to each other and to
the corrected fp32 wrapper:

| comparison | cos p50 | cos min | relL2 p50 | max\|d\| |
| --- | ---: | ---: | ---: | ---: |
| corrected artifact vs corrected torch wrapper | 0.9826 | 0.944 | 0.186 | 16.5 |
| defective artifact vs corrected torch wrapper | 0.9754 | 0.857 | 0.221 | 56.5 |
| corrected vs defective artifact | 0.9958 | 0.890 | 0.092 | 54.9 |

and the corrected↔defective gap **grows with cache depth** (max|d| 13.5 / 20.9 /
45.9 / 54.9 over chunks 1–8 / 8–32 / 32–64 / 64–174), which is the signature of a
mask that only bites once the cache is populated. The corrected artifact is also
closer to the corrected oracle than the defective one on both metrics.

## 3. Pass gate — old (defective) vs corrected

One checkpoint (`shared-consistent-l03`, adapter `l4-streaming`), same rules,
state carried, same-kind ±2-frame matching, `tap_gate.py`.

### 3a. Sample-matched: the one session the old table used (`d622d1e3…`, 1200 frames)

| row | old: drift | old: decisions | corrected: drift | corrected: decisions |
| --- | --- | ---: | --- | ---: |
| control: wrapper 56/0 vs stored shards | cos p50 1.0000, relL2 0.000 | 100% (16/16) | cos p50 1.0000 (p05 0.997), relL2 0.000 | **100% (16/16)** |
| **(1) pass** 42/13 fp32 vs 56/0 | cos p50 0.9925 (p05 0.932), relL2 0.122 | 70.6% (12/17) | cos p50 0.9887 (p05 0.934), relL2 0.150 | 87.5% (14/16) |
| **(2) quant** int8 sim vs 42/13 fp32 | cos p50 0.9939 (p05 0.982), relL2 0.110 | 88.2% (15/17) | cos p50 0.9938 (p05 0.983), relL2 0.111 | 93.3% (14/15) |
| (2b) artifact vs 42/13 fp32 | cos p50 0.9848 (p05 0.961), relL2 0.174 | 94.1% (16/17) | cos p50 0.9848 (p05 0.961), relL2 0.174 | 92.9% (13/14) |
| **(3) product** artifact vs 56/0 | cos p50 0.9741 (p05 0.917), relL2 0.227 | 82.4% (14/17) | cos p50 0.9729 (p05 0.921), relL2 0.232 | 68.8% (11/16) |

The (2b) row reproduces the committed numbers to four decimals because the mask
cancels on both sides — a good control that the pipeline is the same one. The
16-event rows move by ±6% per event and must not be read as precise; they are
here only to keep the old table comparable.

### 3b. The 8-session split the refit used (8 × 2248 frames, 35,968 frame-pairs)

| row | feature drift | decisions |
| --- | --- | ---: |
| control: wrapper 56/0 vs stored shards | cos p50 1.0000, relL2 0.000 | 100% (16/16) — single session, as above |
| **(1) pass** 42/13 fp32 vs 56/0 | cos p50 0.9892 (p05 0.941), relL2 0.147 (p95 0.343) | **81.7% (237/290)** |
| **(2) quant** int8 sim vs 42/13 fp32 | cos p50 0.9928 (p05 0.980), relL2 0.120 (p95 0.198) | 92.1% (257/279) |
| (2b) artifact vs 42/13 fp32 | cos p50 0.9826 (p05 0.960), relL2 0.186 (p95 0.282) | 90.7% (253/279) |
| **(3) product** artifact vs 56/0 | cos p50 0.9687 (p05 0.922), relL2 0.250 (p95 0.396) | **79.2% (232/293)** |

The only 8-session row the old docs have is the product row (`docs/voice-tyger-refit-42-13.md`,
pre-refit, same checkpoint, same split): **83.22% (243/292)** at cos p50 0.9715
(p05 0.9236), relL2 0.239 (p95 0.392). Corrected: **79.18% (232/293)**, cos p50
0.9687, relL2 0.250. Rows (1), (2) and (2b) have no 8-session predecessor; the
single-session rows in 3a are the only sample-matched comparison for them.

### Reading

- **The defect flattered the pass.** A 43-key causal window is closer to the
  reference's 57-key sliding window than the correct 50-key block mask is, so the
  corrupted build drifted *less* (relL2 0.122 vs 0.150; product cos 0.9741 vs
  0.9729) and agreed *more* at the decision level (83.22% → 79.18%). The corrected
  pass is a **20.8 pt** gap to the ≥99% interchangeability bar, not 15.8.
- Quantization is unchanged by the fix (0.9927 vs 0.9939, 0.9848 vs 0.9848); the
  int8 weight grid + fp16 activations still move ~9% of decisions on their own.
- Decision agreement is not monotone in feature drift: on the single session the
  fp32 pass agrees more after the fix (87.5% vs 70.6%) while the product row
  agrees less (68.8% vs 82.4%). With 10–17 events per row that is noise; the
  8-session product row is the one to trust.

## 4. Was the refit needed? Yes — and it still does not close the gap

The corrected pass reaches 79.18% at the product row, far under 99%, so the refit
was re-run on the corrected artifact's taps with the committed recipe: adapter-only
(`l4-streaming`), frozen trunk, warm start `shared-consistent-l03`, `--weights auto`
(P2), λ=0.3, seed 0, 20 epochs @ 1e-3, window 250, featurized through the
mlpackage (60 train + 8 val sessions, 2248 frames each).

Featurization integrity: val shards are structurally identical to `tap4-shards/val`
(**0 problems**: same keys, same T, `np.array_equal` on teacher/energy/prev_state/
all labels/events); live shards likewise against the previous `live-shipping` set
(13 captures, 0 problems).

| | defective-build refit | corrected refit |
| --- | --- | --- |
| probe R² (state/hazard/barge/bc/endpoint) | .764 / .545 / .418 / .519 / .775 | .764 / .550 / .413 / .514 / .778 |
| tensors changed (of 39) | 4, all `adapters.l4-streaming.*` | 4, all `adapters.l4-streaming.*` |
| score gates | pass | pass (state .0077, hazard .0042, barge .0023, bc .0051, endpoint .0264 ≤ .028, hold AUC .913) |

### Teacher agreement (`gate.py`, 8 sessions)

| configuration | old | corrected |
| --- | ---: | ---: |
| pre-refit, 56/0 baseline | 57.38% (175/305) | **57.38% (175/305)** — unchanged, as it must be |
| pre-refit, 42/13 artifact | 57.79% (178/308) | 59.87% (182/304) |
| **refit, 42/13 artifact** | 56.91% (177/311) | **59.22% (183/309)** |
| refit, corpus-calibrated | 59.56% (T=0.8) | 60.76% (T=0.9, ep .90, barge .5, bc .5) |

### Product bars (`harness.py`, 8 sessions, 44 eots, 1 onset, 375 backchannels)

| configuration | ep_lat_s (Δ) | early | miss | bc prec | bc rec | worst-session Δ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| teacher | 0.48 | 10 | 4 | 0.24 | 0.33 | — |
| pre-refit, 56/0 baseline | 0.43 (−0.05) | 9 | 4 | 0.25 | 0.28 | +0.40 s |
| pre-refit, 42/13 artifact (old) | 0.49 (+0.01) | 10 | 4 | 0.24 | 0.26 | +0.64 s |
| pre-refit, 42/13 artifact (corrected) | 0.39 (−0.09) | 9 | 5 | 0.23 | 0.24 | +0.08 s |
| **refit, 42/13, T=1 (old)** | 0.48 (+0.00) | 10 | 4 | 0.24 | 0.32 | +0.48 s |
| **refit, 42/13, T=1 (corrected)** | **0.47 (−0.01)** | 8 | 6 | 0.27 | 0.33 | +0.40 s |
| refit, corrected, corpus fit (T=0.9, ep .90) | 0.30 (−0.18) | 10 | 3 | 0.26 | 0.29 | +0.00 s |

Combined early+miss: baseline 13, pre-refit 14, refit 14 (teacher 14, bar ≈14.9);
mean-of-medians −0.01 (bar ≤ +160 ms). The +320 ms worst-session bar is met by the
corrected rows on this sample and was missed by the baseline under the old features
(+0.40 s): 44 eots over 8 sessions makes this column volatile, so it is reported,
not leaned on.

### Decision-level transfer (`tap_gate.py` / `cross_gate.py`, 8 sessions, ±2 frames)

| comparison | old | corrected |
| --- | ---: | ---: |
| pre-refit: 56/0 ↔ 42/13 (same checkpoint) | 83.22% (243/292) | **79.18% (232/293)** |
| refit: 56/0 ↔ 42/13 (same checkpoint) | 82.65% (243/294) | **78.07% (235/301)** |
| refit@42/13 vs pre-refit@56/0 (product recovery) | 82.09% (243/296) | **80.61% (237/294)** |
| pre-refit@42 vs refit@42 (same features, adapter change) | 84.98% (249/293) | 84.88% (247/291) |
| pre-refit@56 vs refit@56 (same features, adapter change) | 85.96% (251/292) | 81.88% (244/298) |

Note the ordering that matters: adapter-only training moves **more** decisions
(84.9% / 81.9% at identical features) than the corrected pass does (79.2%), and the
refit does not move the swap the right way (78.07% vs 79.18% starting point). The
conclusion of the merged doc — adapter-only training trades one decision surface
for another rather than converging on the 56/0 one — is **stronger** after the fix,
not weaker: the gap is ~19–21 pts, not 16.9.

### Per-domain calibration (`calibrate.py --temp-grid`)

| domain | sessions/events | default | best fit | fitted config |
| --- | --- | ---: | ---: | --- |
| corpus (`tap-shipping-fixed/val`) | 8 / 309 | 59.22% | **60.76%** | T=0.9, ep .90, barge .5, bc .5 |
| live (`live-shipping-fixed`) | 13 / 420 | 49.76% | **58.82%** | T=0.8, ep .88, barge .5, bc .3 |

Cross-domain (one global fit is still a net negative, now by more):

| fit applied | corpus | live |
| --- | ---: | ---: |
| default | 59.22% | 49.76% |
| corpus fit | **60.76%** | 52.86% |
| live fit | 51.58% | **58.82%** |

The corpus fit loses **6.0 pts** on live (was 7.95); the live fit loses **9.2 pts**
on corpus (was 8.39). The live default rate also dropped (52.38% → 49.76%), i.e. the
corrected mask is harder on live audio too. Live rows use 13 captures (~1100 s) and
carry their own selection history — see the merged doc's caveat.

### fp32/int8 export parity (student step, 2248 real val frames)

| variant | probs max\|d\| | flips | latency | bytes |
| --- | --- | --- | --- | --- |
| fp32 ONNX | **1.43e-06** (1e-4) **PASS** | 0 argmax, 0 threshold | 0.064 ms/step | 5.28 MB |
| int8 group-16 | **1.07e-02** (2e-3) **FAIL** | 1 argmax, 2 bc threshold | 0.249 ms/step | 1.75 MB |

QAT is still required before shipping the int8 student; the refit did not change
that (the old projection measured 7.78e-3, also FAIL).

## 5. What this changes, and what it does not

- **Not changed:** the 56/0 reference pass, its shards, the thresholds, the bar,
  the shipped artifacts. The reference selfcheck is bit-identical (3.529e-05) and
  the 56/0 teacher baseline reproduces exactly (175/305).
- **Changed:** the 42/13 pass is further from 56/0 than the defective build
  suggested (relL2 0.147/0.250 vs 0.122/0.239 at the product row; decisions
  79.18% vs 83.22%). The interchangeability bar is **not** met and the remaining
  lever is unchanged: shared-trunk retraining on 42/13 features, or accepting the
  42/13 decision distribution as a new reference. Per-domain calibration remains
  mandatory for whichever reference is chosen.
- **Process:** a mask that only existed as prose is what let this survive. The
  geometry is now a test; the second-implementation oracle the blocker report asks
  for (an independent shipping NeMo encoder reproducing per-chunk outputs and cache
  transitions) is still the right next check — this fix is our reading of their
  mask, checked against our own arithmetic, not against their graph.

## 6. Artifacts and reproduction

All paths are in the re-measurement worktree (`t3/remeasure-42-13-after-mask-fix`);
`bench-results/` is gitignored.

| path | what |
| --- | --- |
| `bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage` | corrected artifact (593,446,155 B) |
| `bench-results/asr-tap-defect-mask/` | **the defective artifact, kept for comparison** (+ `MANIFEST.md` with both hashes) |
| `bench-results/tap-shipping-fixed/{train,val}` | corrected artifact taps (60 + 8 shards; `val` → `artifact/`) |
| `bench-results/tap-shipping-fixed/{fp32,int8sim,artifact}` | the three feature sources for the gate rows |
| `bench-results/tap-shipping-fixed/refctrl` | 56/0 control emission (1 session) |
| `bench-results/tap-shipping-fixed/one/` | the single-session (1200-frame) slice used for 3a |
| `bench-results/live-shipping-fixed/` | 13 live captures through the corrected artifact |
| `bench-results/shared-shipping-refit-fixed/` | refit checkpoint, corpus + live traits |
| `bench-results/asr-tap-fixed/{gate,logs}/` | every JSON/table quoted above |

```sh
PY=ports/tyger-student/.venv/bin/python
MAIN=/Users/don/dev/idfon/bench-results
FIX=bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage

$PY ports/tyger-student/test_asr_tap_mask.py -v                      # mask geometry
$PY ports/tyger-student/asr_tap.py --selfcheck                       # reference, 3.53e-05
$PY ports/tyger-student/export_asr_tap.py --export --pass shipping \
    --precision fp16 --int8 --out bench-results/asr-tap-fixed        # + fixture gate

# feature sources (8 val sessions x 2248 frames), then the gate rows
$PY ports/tyger-student/pass_gate.py --emit-shards bench-results/tap-shipping-fixed/fp32 \
    --pass shipping --split val --shards $MAIN/tap4-shards/val --sessions 8 --frames 2248
$PY ports/tyger-student/pass_gate.py --emit-shards bench-results/tap-shipping-fixed/fp32 \
    --pass shipping --split val --shards $MAIN/tap4-shards/val --sessions 8 --frames 2248 --int8
$PY ports/tyger-student/pass_gate.py --emit-shards bench-results/tap-shipping-fixed/artifact \
    --pass shipping --split val --shards $MAIN/tap4-shards/val --sessions 8 --frames 2248 --artifact $FIX
$PY ports/tyger-student/tap_gate.py --student $MAIN/shared-consistent-l03/student.pt \
    --tap l4-streaming --shards-a $MAIN/tap4-shards/val --shards-b bench-results/tap-shipping-fixed/artifact

# refit (adapter-only, frozen trunk) and its gates — same recipe as the merged doc
$PY ports/tyger-student/train_shared.py --tap l15-windowed=$MAIN/student-shards \
    --tap l4-windowed=$MAIN/l4-shards --tap l4-streaming=bench-results/tap-shipping-fixed \
    --init $MAIN/shared-consistent-l03/student.pt --adapter-only l4-streaming --weights auto \
    --consistency 0.3 --seed 0 --epochs 20 --lr 1e-3 --window 250 \
    --deploy-tap l4-streaming --out bench-results/shared-shipping-refit-fixed
$PY ports/tyger-student/cross_gate.py --a-student $MAIN/shared-consistent-l03/student.pt \
    --a-shards $MAIN/tap4-shards/val --b-student bench-results/shared-shipping-refit-fixed/student.pt \
    --b-shards bench-results/tap-shipping-fixed/artifact --label "refit@42 vs pre@56"
```
