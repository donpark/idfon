# Refit the `l4-streaming` adapter for the shipping 42/13 pass (#102 / #132)

Status: **measured** (2026-11-05). The adapter recovers the 56/0 baseline's
**aggregate** teacher agreement and product bars, but adapter-only training does
**not** restore decision-level transfer: the refit still changes ~17% of the
56/0 reference decisions. The next lever (retraining the shared trunk on 42/13
features, or accepting the 42/13 decision distribution as a new reference) is a
separate decision. Do not read the aggregate recovery as a ≥99% parity pass.

Base: `26f7cde` (main: tap export + fork pin + #168 baseline instrument).
Artifact: `encoder_tap_42-13_fp16_int8w.mlpackage`, **593,446,722 B**,
`tap_l4 [1,1024,7]`, 42/13 pass, int8 weights + fp16 activations.
Measured in the export gate: **9.62 ms/chunk ANE**, 20.40 ms/chunk CPU
(the documented reference is 9.0 ms / ANE).

## Why a refit

`tap_gate.py` on one 96 s session (17 events) put the pre-refit adapter at
**82.4%** decision agreement between the 42/13 artifact and the 56/0 reference
(the tap-swap bar is ≥99%). The pass alone was 70.6%, quantization alone
88–94%. The simulated int8 quantizer sits cos 0.978 from the artifact, so the
refit must fit on taps emitted **through the artifact**, not the simulation.

## Features: emitted through the artifact, verified frame-aligned

`pass_gate.py --emit-shards --artifact` at 42/13 int8 over the dualturn corpus
(60 train + 8 val sessions). Only `hu`/`ha` are replaced; the teacher 8-vector,
energy, prev-state, every `lab_*` column, and the event tables are copied
verbatim.

- Train: 60 shards; Val: 8 shards. All 2248 frames.
- Structural check against `tap4-shards`: **0 problems** (same keys, same T,
  `np.array_equal` on teacher/energy/prev_state/all labels/events, same
  `hu`/`ha` shapes).
- Feature drift vs the 56/0 shards over **35,968 frame-pairs** (both ears):
  cos p50 **0.9715** (p05 0.9236), rel-L2 p50 **0.239** (p95 0.392).

Post-refit sample: **8 sessions, 17,984 frames (1439 s), 299 teacher events**
(previous pass-gate sample: 1 session, 96 s, 17 events).

## Training: adapter-only, frozen trunk

`train_shared.py` with all three adapters present, `--adapter-only l4-streaming`,
warm start `shared-consistent-l03`, `--weights auto` (P2 per-axis probe rule),
`--consistency 0.3`, seed 0, 20 epochs @ lr 1e-3, window 250. The other two
adapters are frozen and carried through unchanged.

Probe R² on the 42/13 artifact features (per-axis teacher weights):
state **0.764** (w 1.265), hazard **0.545** (0.902), barge **0.418** (0.692),
backchannel **0.519** (0.859), endpoint **0.775** (1.282). At parity with the
56/0 probe table (state .73, hazard .53, barge .39, bc .41, endpoint .75).

Byte-identity check (not assumed): of 39 state-dict tensors, **4 changed**, all
`adapters.l4-streaming.*`; `l15-windowed`, `l4-windowed`, and the shared
trunk/decoder/heads are `torch.equal` to the warm start.

Score gates on the new val shards: state .00804, hazard .00425, barge .00236,
bc .00507, endpoint **.02710** (L4 ceiling .028), hold AUC .897 — all pass.

## Teacher agreement (`gate.py`; 8 sessions, 299 reference events)

| configuration | features | agreement | events |
| --- | --- | ---: | ---: |
| pre-refit, 56/0 baseline | `tap4-shards/val` | **57.38%** | 175/305 |
| pre-refit, 42/13 artifact | `tap-shipping/val` | 57.79% | 178/308 |
| **refit, 42/13 artifact** | `tap-shipping/val` | **56.91%** | 177/311 |
| refit, corpus-calibrated (T=0.8) | `tap-shipping/val` | **59.56%** | — |

The refit is within **0.47 pt** of the 56/0 baseline on the same 8 sessions. The
pass change alone barely moved this aggregate; the failure the refit targets is
decision-level (below), not teacher agreement.

## Product bars (`harness.py`; 8 sessions, 44 eots, 1 onset, 375 backchannels)

`ep_lat_s` is the mean of per-session median endpoint latencies; early/miss are
sums. Teacher row is the same on all three.

| configuration | ep_lat_s (Δ) | early | miss | bc prec | bc rec | worst-session Δ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| teacher | 0.48 | 10 | 4 | 0.24 | 0.33 | — |
| pre-refit, 56/0 baseline | 0.43 (−0.05) | 9 | 4 | 0.25 | 0.28 | +0.40 s |
| pre-refit, 42/13 artifact | 0.49 (+0.01) | 10 | 4 | 0.24 | 0.26 | +0.64 s |
| **refit, 42/13, T=1** | **0.48 (+0.00)** | 10 | 4 | 0.24 | **0.32** | +0.48 s |
| refit, 42/13, corpus T=0.8 | 0.39 (−0.09) | 10 | 2 | 0.23 | 0.27 | — |

Combined early+miss: baseline 13, pre-refit 14, refit 14 (teacher 14; bar
≤ teacher + 2 pts of eots ≈ 14.9) — pass. Mean-of-medians is +0.00 (bar
≤ +160 ms) — pass. The +320 ms **worst-session** bar is not met by any row on
this sample, including the 56/0 baseline (+0.40 s); the refit sits between the
baseline (+0.40) and the pre-refit 42/13 state (+0.64), so it is not a refit
regression. The P2 table's 13-session/139-eot sample is a different set.

## Decision-level transfer: the gap is here

`tap_gate.py`, 8 sessions, ±2 frames, same-kind matching:

| comparison | agreement | events |
| --- | ---: | ---: |
| pre-refit: 56/0 ↔ 42/13 (same checkpoint) | **83.22%** | 243/292 |
| refit: 56/0 ↔ 42/13 (same checkpoint) | **82.65%** | 243/294 |
| refit@42/13 vs pre-refit@56/0 (product recovery) | **82.09%** | 243/296 |
| pre-refit@42 vs refit@42 (same features, adapter change) | 84.98% | 249/293 |
| pre-refit@56 vs refit@56 (same features, adapter change) | 85.96% | 251/292 |

Reading: the refit did **not** make the adapter pass-invariant (82.65% vs the
83.22% starting point), and its deployment decisions agree with the 56/0
reference at **82.09%** — 16.9 pts under the 99% bar and no better than the
pre-refit pass change. Changing the adapter alone moves ~15% of decisions even
on the *same* feature source (84.98% / 85.96%), so adapter-only training is
trading one decision surface for another, not converging to the 56/0 one. The
measurement that shows the gap is the `tap_gate.py` pair above (and the
cross-checkpoint replay); the aggregate gate/harness tables do not show it.

## Per-domain calibration (`calibrate.py --temp-grid`)

| domain | sessions/events | default | best fit | fitted config |
| --- | --- | ---: | ---: | --- |
| corpus (`tap-shipping/val`) | 8 / 299 | 56.91% | **59.56%** | **T=0.8**, ep .9146, barge .5, bc .5 (NLL T=0.8) |
| live (`live-shipping`, 13 captures) | 13 / — | 52.38% | **59.14%** | **T=1.0**, ep .85, barge .5, **bc .3** (NLL T=0.8) |

Cross-domain penalty (one global fit is a net negative):

| fit applied | corpus | live |
| --- | ---: | ---: |
| default | 56.91% | 52.38% |
| corpus fit | **59.56%** | 51.19% |
| live fit | 51.17% | **59.14%** |

The corpus fit loses **7.95 pts** on live; the live fit loses **8.39 pts** on
corpus. The domains want different temperatures *and* different thresholds
(live bc .3 vs corpus .5), confirming P4's per-domain rule for this refit.

## fp32/int8 export parity (student step, 2248 real val frames)

| variant | probs max|d| (gate) | flips | latency | bytes |
| --- | --- | --- | --- | --- |
| fp32 ONNX | **2.59e-06** (1e-4) **PASS** | 0 argmax, 0 threshold | 0.044 ms/step | 5.28 MB |
| int8 group-16 | **7.78e-03** (2e-3) **FAIL** | 1 argmax, 2 bc threshold | 0.233 ms/step | 1.75 MB + 0.01 MB |

Int8 still needs the P4 QAT fine-tune (project the export grid, 20 ep @ 1e-4)
before shipping; the adapter refit does not change that. The refit checkpoint is
2,369,033 params (9.5 MB fp32).

## Stop-rule verdict

- **Teacher agreement:** refit 56.91% vs 56/0 baseline 57.38% — recovered
  (Δ −0.47 pt, within the 8-session noise).
- **Product bars:** combined early+miss 14 vs baseline 13 (teacher 14, bar
  ≈14.9) and mean-of-medians Δ +0.00 — recovered; worst-session latency +0.48 s
  is between the baseline's +0.40 and the pre-refit's +0.64, and the +320 ms bar
  is already missed by the baseline on this sample.
- **Decision transfer:** **not recovered.** The refit@42/13 product decisions
  match the pre-refit@56/0 reference at **82.09%**, and the same-checkpoint
  pass-swap is **82.65%** — a **16.9 pt gap to the 99% bar**, statistically the
  same as the pre-refit 83.22%. The next lever (shared-trunk retraining on 42/13
  features) is a separate decision.

## Reproduce

```sh
PY=ports/tyger-student/.venv/bin/python
MAIN=/Users/don/dev/idfon/bench-results

# artifact (593 MB) — regenerate if bench-results/asr-tap is absent
$PY ports/tyger-student/export_asr_tap.py --export --pass shipping --precision fp16 --int8 --out bench-results/asr-tap

# one-pass wav cache (the emit path otherwise re-streams the 25 GB split per session)
$PY ports/tyger-student/precache_wavs.py --shards $MAIN/tap4-shards/train --split train --out bench-results/asr-tap/wav
$PY ports/tyger-student/precache_wavs.py --shards $MAIN/tap4-shards/val   --split val   --out bench-results/asr-tap/wav

# featurize through the artifact
$PY ports/tyger-student/pass_gate.py --emit-shards bench-results/tap-shipping/train --pass shipping --split train \
    --shards $MAIN/tap4-shards/train --sessions 60 --frames 2248 \
    --artifact bench-results/asr-tap/encoder_tap_42-13_fp16_int8w.mlpackage
$PY ports/tyger-student/pass_gate.py --emit-shards bench-results/tap-shipping/val --pass shipping --split val \
    --shards $MAIN/tap4-shards/val --sessions 8 --frames 2248 \
    --artifact bench-results/asr-tap/encoder_tap_42-13_fp16_int8w.mlpackage

# adapter-only refit
$PY ports/tyger-student/train_shared.py \
    --tap l15-windowed=$MAIN/student-shards --tap l4-windowed=$MAIN/l4-shards \
    --tap l4-streaming=bench-results/tap-shipping \
    --init $MAIN/shared-consistent-l03/student.pt --adapter-only l4-streaming \
    --weights auto --consistency 0.3 --seed 0 --epochs 20 --lr 1e-3 --window 250 \
    --deploy-tap l4-streaming --out bench-results/shared-shipping-refit

# per-domain calibration (corpus + live artifact features)
$PY ports/tyger-student/calibrate.py --shards bench-results/tap-shipping/val \
    --student bench-results/shared-shipping-refit/student.pt --tap l4-streaming \
    --temp-grid 0.8,0.9,1.0,1.1,1.25 --out bench-results/shared-shipping-refit/corpus.traits.json
$PY ports/tyger-student/featurize_live_artifact.py \
    --wavs "$HOME/Library/Application Support/Idfon/turn-captures" \
    --shards $MAIN/live-shards-l4-all --out bench-results/live-shipping \
    --artifact bench-results/asr-tap/encoder_tap_42-13_fp16_int8w.mlpackage
$PY ports/tyger-student/calibrate.py --shards bench-results/live-shipping \
    --student bench-results/shared-shipping-refit/student.pt --tap l4-streaming \
    --temp-grid 0.8,0.9,1.0,1.1,1.25 --out bench-results/shared-shipping-refit/live.traits.json

# gates
$PY ports/tyger-student/gate.py    --shards bench-results/tap-shipping/val --student bench-results/shared-shipping-refit/student.pt --tap l4-streaming
$PY ports/tyger-student/harness.py --shards bench-results/tap-shipping/val --student bench-results/shared-shipping-refit/student.pt --tap l4-streaming [--temp 0.8]
$PY ports/tyger-student/tap_gate.py --student bench-results/shared-shipping-refit/student.pt --tap l4-streaming \
    --shards-a $MAIN/tap4-shards/val --shards-b bench-results/tap-shipping/val --sessions 8
$PY ports/tyger-student/export.py --student bench-results/shared-shipping-refit/student.pt --tap l4-streaming \
    --shards bench-results/tap-shipping/val --frames 2248 --group 16
```
