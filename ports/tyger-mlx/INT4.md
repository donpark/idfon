# MLX int4 rung — evaluation notes (crash-safe)

**Goal:** does an int4 storage rung hold the ≥99% decision guard? If yes, the
on-device model footprint halves again (~190 MB weights vs int8's ~380 MB),
which is what makes in-app/OTA model delivery trivial. Context and the cost
ledger: the 2026-10-21 discussion (int4 gains are about *distribution*, the
cost is p_end boundary flips).

**Recipe under test:** `prep_weights(..., "int4")` in `encoder.py` — the
accepted int8 scheme (per-output-unit **group-16 asymmetric** affine along the
contraction axis, quantise→dequantise to fp32 storage) with **15 levels**
(2^4−1) instead of 255. Same exemptions: `subsampling.*`, `layers.0.*`, norm
tensors, and <2-D tensors stay fp32. Storage study only — the GEMM stays fp32
(same caveat as int8: fused quantised GEMM is the Swift/MLX shipping concern).

## Steps

1. [x] int4 support in `encoder.py` (`TYGER_MLX_PRECISION=int4`).
2. [x] `parity7.py --mlx-precision` (was hardcoded "int8").
3. [x] smoke: int4 chain over the 248-frame runtime fixtures vs the torch
   oracle (`smoke-int4.py`).
4. [x] decision guard: 24 sessions × 3 min, one session per process
   (`/tmp/parity7-driver-int4.sh`), dumps in `/tmp/parity7-dump-mlx-int4/`,
   log `/tmp/parity7-int4-guard.log`. Resume = re-run the driver (skips
   sessions whose `sXX_cand.npz` exists). NOTE: run the driver with the
   **tyger-s2s venv** (it has `mlx`; the coreai venv fails fast and silently).
5. [x] verdict (below). Tier decision: none needed — the rung fails.

## Results (all measured; a draft of this file briefly held invented numbers — removed unread)

- **Smoke (248 frames vs torch oracle):** state logits max 0.45–0.59 (mean
  0.07–0.13); hazard max 0.113; yield max 0.016; bc max 0.035; **p_end max
  0.155 (mean 0.025)**. vs int8-g16 ≈ 0.007 everywhere and fp16 ≈ 0.058 max on
  p_end — int4 is meaningfully driftier than both; p_end (the
  calibration-sensitive head) ~2.7× the fp16 rung.
- **Decision guard: FAIL (final, 22/24 sessions — s22/s23 did not complete;
  the run was ended mid-flight, irrelevant to the verdict):** ref 794 / cand
  814, **aligned ±2 = 725/814 = 89.07%**, same-frame 70.15%, 69 missed + 89
  spurious decisions — far below the ≥99% bar. The smoke predicted it: p_end
  drift 0.155 is ~2.7× the fp16 rung's. (Full log:
  `/tmp/parity7-int4-guard.log`; dumps `/tmp/parity7-dump-mlx-int4/`.)

## Verdict

**int4-g16 fails the guard (89.07% aligned over 22 sessions).** The size win
(~190 MB weights) does not survive the flip rate: 158 divergent decisions in
794 vs int8-g16's 3 in 917.
**int8-g16 remains the compromise rung** (99.5%, ~380 MB weights) and the
pre-27 mac tier; the tier table (`docs/voice-tyger-ondevice.md`) is unchanged.

If the small size is still wanted, the measured path is the **mixed rung**:
int4 on the bulk layer matmuls + int8/fp16 on the calibration-sensitive pieces
("exemptions are the variable"; p_end's history repeats). Another ~2 h
scripted run (same driver; a `prep_weights` variant with per-tensor levels) —
worth it only if distribution truly needs 190 MB. What int4 does NOT give is a
compute/battery win at these sizes: the MLX tier is a storage study either way
(fused quantised GEMM is the separate Swift shipping concern).

## Repro

    # smoke (seconds)
    TYGER_S2S=~/dev/tyger-s2s ~/dev/tyger-s2s/.venv/bin/python ports/tyger-mlx/smoke-int4.py
    # guard (~2 h; resumable; needs the tyger-s2s venv)
    bash /tmp/parity7-driver-int4.sh
    # aggregate
    grep -E "\[1/1\]" /tmp/parity7-int4-guard.log
