# Core AI gate transcripts

Every shipped Core AI bundle is judged by gates, not checksums (conversion is
not byte-deterministic). This file is the transcript record — revision, inputs,
outputs, verdict — per the coreai-model-zoo discipline. Harness env:
`ports/tyger-coreai/.venv` (python 3.12; see ports/tyger-coreai/README.md).
Reference chain: the torch oracle (tyger bundle, `nineninesix/tyger` snapshot
`a5d4d73b…`); harnesses `ports/tyger-coreai/export_turn.py` and
`ports/tyger-coreml/parity7.py --cand coreai`.

## tyger_encoder_float32.aimodel + tyger_step_float32.aimodel

- Date: 2026-10-19
- Source: `ports/tyger-coreml/export.py` wrappers (EncWrap = HF encoder →
  hidden_states[15]; StepWrap = the 14M turn head with in-graph energy
  normalisation), exported by `ports/tyger-coreai/export_turn.py`
  (`dynamic_shapes={"feats": {1: 8*Dim("_mel",5,101)-7}}` for the encoder).
- Device posture: GPU (ANE compiler internal error on the dynamic encoder;
  CPU specialization fails on the step graph).

### Export gates (export_turn.py --only gate, real fixture audio)

| Gate | Input | Result |
|---|---|---|
| step vs torch, gpu | random hu/ha (1,1,1024), act −30 dB, state 0 | max\|Δ\| 0.0, cos 1.0 |
| encoder vs torch, gpu | ch0.wav 8 s window (801 mel) | max\|Δ\| 0.000076, cos 1.000000 |
| encoder vs torch, gpu | ch0.wav 3 s window (301 mel) | max\|Δ\| 0.000103, cos 1.000000 |
| encoder vs torch, cpu | both windows | max\|Δ\| 0.000122 / 0.000092, cos 1.000000 |

### Swift runtime gates (ports/tyger-swift CoreAISoakTests)

| Gate | Result |
|---|---|
| full chain vs the oracle, 248 frames (ch0/ch1.wav, 62 hops) | exact within the fp32 envelope (all 8 heads) |
| soak: 30,000 step calls in one process | clean, 41 s — the per-call IOSurface leak is Python-binding-only |

### Decision guard (parity7 --cand coreai vs the fp32 CoreML reference)

| Sessions | Frames | Decisions | Per-head drift |
|---|---|---|---|
| **24 (final)** | **53,952** | **917/917 at the identical frame = 100.0%** | max 6e-5, mean ≈ 0 |

Known non-issues recorded elsewhere: the Python binding's per-call IOSurface
leak (harness must shard by process and run sequentially — system-wide Metal
resource drain under concurrency); `expectFrequentReshapes=true` corruption.

## The fp16 rung (2026-10-21, tyger_encoder_float16.aimodel + tyger_step_float16.aimodel)

fp16 compute behind **fp32 I/O** (the `EncIO32`/`StepIO32` wrappers in
`export_turn.py` — the app and the gates keep feeding fp32, like the CoreML
fp16 pair). Export gates (`export_turn.py --precision float16`):

| Gate | Result |
| --- | --- |
| step vs torch, gpu | max\|Δ\| 0.000977 (~1 fp16 quantum), cos 1.000000 |
| encoder vs torch, gpu+cpu | max\|Δ\| 1.06, cos 0.999975 (the known fp16 encoder drift class) |

Decision guard (parity7 --cand coreai --coreai-precision float16, 24 sessions ×
3 min, one session per process):

| Sessions | Frames | Decisions (ref/cand) | Aligned ±2 | Same-frame | Divergent |
| --- | --- | --- | --- | --- | --- |
| **24** | **53,952** | **917 / 919** | **916/919 = 99.67%** | 891/919 = 96.95% | 4 (1 missed + 3 spurious, all boundary flips) |

**PASS** against the ≥99% bar — marginally better aligned than the MLX int8-g16
tier (99.5%), marginally worse same-frame (97.8% there). Size ≈ half of fp32
(~0.77 GB vs 1.53 GB). Dumps: /tmp/parity7-dump-coreai-fp16/.

**Chosen as the OS 27+ shipping rung (user, 2026-10-21).** `CoreAITurnModel`
prefers the float16 pair and falls back to the float32 assets (the exact tier).

**Provisioned into the loader's path (2026-10-26)**: `bench-results/coreai`
now carries both rungs (fp32 1.53 GB + fp16 793 MB) — until today only the
fp32 pair was there, so every loader silently ran the exact tier. Re-exported
with `TYGER_S2S=/Users/don/dev/github/tyger-s2s`, gates re-run PASS (step
max|Δ| 0.000977; encoder 0.25–1.0 at cos 0.999975, the known fp16 drift
class). Swift `CoreAITurnModel` (now reports `usesFloat16`) passes
`testRuntimeMatchesTheOracle` on the fp16 pair inside parity6's envelope
(measured state ≤ 0.038, probs ≤ 0.010 on the 248-frame fixture). The HF
manifest has served the fp16 pair since 2026-10-21 (the iOS install path).

**Superseded (2026-10-27)**: the corner gate (`scripts/corpus-corner.py`) shows
the fp16 rung never ends a margin turn (0 endpoints; `p_end` drift ≈ 0.03 — the
99.67% guard missed it because real conversations rarely sit on the margin).
fp32 is the default rung again (`CoreAITurnModel`, loader-enforced); fp16 is
opt-in via `IDFON_TURN_PRECISION=fp16`. The HF manifest now serves the fp32
pair + the `.h17p` (A18/A18 Pro) AOT containers. Two delivery defects fixed
with it: `url_base` was packed null (manifest decode fails → the store could
never fetch anything), and the store was never wired (now behind the
`VoiceModelGate` approval; see `docs/voice-tyger-ondevice.md`).
