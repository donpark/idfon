# tyger-student — the decision-head platform (P1 of `docs/voice-decision-model.md`)

The trainable replacement for the frozen Tyger turn-taker: one shared small trunk
(~1.3M params, ~5.3 MB fp32 vs the 14M/56 MB teacher) with **one linear head per
decision point**. This is the thing to invest in: adding a decision point is a
registry entry plus labels — not another bolted-on model.

| File | Role |
| --- | --- |
| `registry.py` | **the investment surface** — every decision point: type, label source, loss, gate; plus the shared-latent spec (epic #132): `ADAPTERS` (per-tap z-adapters) + `LATENT_WIDTH` |
| `model.py` | the student (width-256 2-layer GRU over two 1,024-d feature streams — L15 or L4 — + energy + floor state) and the unchanged rules-seam 8-vector; `SharedLatentStudent` (epic #132): per-tap adapters → one shared causal latent `z` → one decoder, same 8-vector |
| `featurize.py` | corpus → training shards: what the model sees + what the teacher answered + the teacher's events, per 80 ms frame |
| `data.py` | the shard format (the wire between featurize, train and gate) |
| `train.py` | distillation + label training, per-head score gate report, warm start for batch N+1 (`--selfcheck` for a synthetic smoke) |
| `calibrate.py` | per-model fit of the rules' threshold knobs (ep/barge/bc) → `<student>.traits.json`; reports default AND calibrated agreement |
| `gate.py` | the decision gate: student's own events vs the teacher's, replayed with live rules feedback (parity7 metric, ≥99% PASS) |
| `export.py` | the size rung: `student.pt` → ONNX (`StudentStep{,Int8}.onnx`, TygerStep I/O contract) + parity gates (fp32 ≤ 1e-4, int8 probs ≤ 2e-3, decision-flip counts) |
| `export_coreml.py` | the apps' pre-27 tier: `StudentStep.mlpackage` (fp32, ANE-fp16-exempt by ruling) + carried-state parity |
| `export_coreai.py` | the apps' OS-27 tier: `student_step_float32.aimodel` + AOT `.aimodelc` container (loader-enforced; source loads leak ANE compiles) + coreai.runtime gate |
| `harness.py` | the product-metric gate (the P1 brief's judgment): endpoint latency/early/miss, barge catch/false, bc precision/recall — teacher vs student on the same axes (`scripts/tyger-eval.py` definitions; proposed bars in `bench-results/harness-gate.md`) |
| `oracle.py` | the tyger-s2s seam (reference chain + rules + Mimi decode), one env contract |
| `probe.py` | the tap probe survey (#132 P0): per-tap ridge probes (R²/cosine) of the teacher's 8-vector per decision axis, held-out sessions; the tap-quality table that drives the per-axis adapter loss weights (`bench-results/tap-probes.md`, findings in `docs/voice-decision-model.md` P2) |
| `test_model.py` | the shipped checkpoint-layout pin (student.pt loads by name) + the shared-latent seam smoke |

## Contract (unchanged above the seam)

Same inputs as the teacher's turn-taker (caller/agent 1,024-d features — L15 for
the teacher/L15 student, L4 for the shipped L4 student — + frame energy +
previous floor state per 80 ms frame), same 8-vector out (4 state logits,
hazard, yield, bc, p_end), same rules seam (`crates/idfon-voice/src/turns.rs`,
`TurnRulesCABI`) — so `TurnShadow`, traits, and the decision log consume the student
identically. Fail-open to classic is untouched.

## The shared latent (epic #132, P1)

The multi-tap contract behind the P2/P3 work, encoded in `registry.py` and
instantiated by `model.py`'s `SharedLatentStudent`:

- **Adapters** (`registry.ADAPTERS`) map one tap's two streams into the fuse
  width — one per (layer, pass): `l15-windowed`, `l4-windowed`, `l4-streaming`
  (the deploy target), `l24-streaming`, `l15-streaming` (declared, extraction
  unwired). `kind: "aux"` is reserved for auxiliary-signal adapters (#131).
- **One shared causal latent `z`** (width-256 2-layer GRU over the summed fuse
  inputs) and **one decoder** (out_norm + registry heads) behind the unchanged
  8-vector seam. Every adapter trains toward the same decision endpoint; deploy
  exactly one adapter — the tap the streaming ASR already computes.
- Cross-adapter calls on the same frames are the P3 consistency-loss surface
  (KL between decisions via tap A and tap B). Per-axis teacher weighting (P2)
  comes from `probe.py`'s tap-quality table, never from averaged teachers.
- The existing `Student` is untouched — its checkpoint layout is pinned by
  `test_model.py` (the shipped tiers load by name).

## The loop: add a decision point

1. **Registry entry** (`registry.py`): id, kind (`noul`/`choice`/`score`, the System
   One types of `docs/voice-decisions.md`), `source`, loss, gate. Seed heads in the
   table show both label families: teacher distillation (`teacher:<cols>`) and
   corpus labels (`corpus:<key>` — e.g. `hold`, the first decision point the teacher
   does not have). `outcome:`/`gold:` (decision-log weak labels / human labels,
   `docs/voice-decisions.md`) are declared but not wired yet.
2. **Labels in the shards**: `featurize.py` carries the corpus keys; a new key or a
   new source means a re-run (the loader fails loudly if the labels are missing).
3. **Train**: `train.py --shards bench-results/student-shards/train --val bench-results/student-shards/val --out bench-results/student`.
   For teacher-only pseudo-label shards (no `hold_ch0` human/corpus label), use `--head-set teacher-seam`; this trains only the five Tyger heads and keeps the same 8-vector seam.
4. **Gates**: `train.py`'s report checks each head against its registry gate (`mse` ≤
   the 0.02 parity envelope for teacher heads; `auc` bars get set after run 1, the way
   parity6/7 did), and `gate.py` checks the decisions themselves (parity7 agreement
   vs the recorded teacher events). Exit codes 1 on failure.
5. **Calibrate** (`calibrate.py`): fit the rules' threshold knobs per model and ship
   the student with its own `<student>.traits.json` — optima don't transfer between
   models (see bench-results/gate-calibration.md). Always report **both** default and
   calibrated agreement: default = self-contained behavior, calibrated = product config.
6. **Export** (done — all three delivery tiers, all gated):
   - ONNX (`export.py`): `StudentStep.onnx` (5.28 MB fp32; probs Δ 2.4e-7) and
     `StudentStepInt8.onnx` (2.16 MB int8 group-8; probs Δ 1.63e-3 ≤ 2e-3, 0 argmax
     flips, 1/248 p_end threshold flip) — the eve TS agent's tier. **fp32 is the
     shipping default** (user ruling 2026-11-01: 3 MB against a >1 GB download is
     noise — the encoder is the whole size story). int8 is the shelf-ready variant
     for constrained tiers (watch/embedded/RAM) and for post-L4-tap sizes; its real
     value was proving quantizability (the robustness certificate) — and it caught a
     shared-quantizer bug.
   - CoreML (`export_coreml.py`): `StudentStep.mlpackage` fp32 (5.3 MB; Δ 5.7e-6 on
     carried-state frames) — the apps' pre-27 tier.
   - CoreAI (`export_coreai.py`): `student_step_float32.aimodel` + AOT
     `.h16s.aimodelc` (5.3 MB; Δ 1e-6 on the coreai.runtime gate) — the apps' OS-27 tier.
   **QAT not needed** — every gate passes post-training. Env note: coreai-models
   installs from `~/dev/coreai-models/python` (the `~/dev/github/coreai-models`
   checkout is stale and its converter crashes on fused LayerNorm locs).

## In the product (step swap, issue #104)

`pnpm tyger build` stages each export beside the teacher's artifact
(`bench-results/coreai/student_step_float32.*`, `bench-results/coreml/StudentStep.mlpackage`,
`bench-results/onnx/StudentStep.onnx`), so every loader prefers the student and
the packers pick it up without a second path:

| Consumer | Preference | State shape source |
| --- | --- | --- |
| `ios/Idfon/TurnShadow.swift` (CoreAI / CoreML) | `CoreAITurnModel`, `CoreMLTurnModel` | model description / step family |
| `mac/Sources/Idfon/TurnShadow.swift` (CoreAI) | same, over the checkout's `bench-results/tier-l4/coreai` (L15 `bench-results/coreai` fallback) | step family |
| `integrations/eve-idfon-voice/src/tyger/` | `bundle.ts` (`StudentStep.onnx`) | manifest `io.step.inputs.state` |
| `scripts/pack-tyger-models.mjs` | ships both steps, student first | — |

Traits are **per model**, so both live here:

| File | Model | Triple | Where it came from |
| --- | --- | --- | --- |
| `student.traits.json` | the P1 L15 student (this README's pipeline) | 0.85/0.4/0.4 | the 2026-11-01 live-call pass: 64.4% event agreement at 0.85 vs 55.7% at 0.9146 on 8 app captures (18 min), stable leave-one-session-out; bc 0.4 confirmed; barge measured on the 7-capture follow-up: 4/20 at 0.40 (12 false; 4 during playback), 15/20 at 0.10 but 128 false; no Open Yap edge over L4 |
| `student-l4.traits.json` | the L4 student shipped with the L4 encoder cut (#102) | 0.75/0.5/0.5 | the pooled 13-session live fit: 56.60% event agreement vs 48.81% at 0.9146; this is the file the live bundle carries (`coreai|coreml/student.traits.json`, 182 B) |

`pnpm tyger build` stages `student.traits.json` beside its own student. The L4
tier root must carry `student-l4.traits.json` **renamed to `student.traits.json`**
when it is packed — a tier root holding the L15 file would ship the wrong model's
thresholds. Re-run the live fit as captures accumulate:

```sh
ports/tyger-student/.venv/bin/python ports/tyger-student/featurize.py \
    --wavs "$HOME/Library/Application Support/Idfon/turn-captures" --out bench-results/live-shards
ports/tyger-student/.venv/bin/python ports/tyger-student/calibrate.py \
    --shards bench-results/live-shards --student bench-results/student/student.pt
```

Barge is measured on two paths (20 live-call onsets + Open Yap 1K); on the live
captures the student's compressed yield head (L4 0.42×teacher) under-fires vs the
teacher below barge_thr 0.5, but at 0.5 it fires 8× fewer false barges (2 vs 16)
and matches the teacher's catch at equal false-fire budgets — see
`bench-results/barge-live.md`.

## The organic loop: new batches of real conversations

Improvement is exposure: `featurize.py` turns each new batch of conversations into
shards, `train.py --init student.pt` warm-starts from the previous student on the
accumulated shards (heads new since the checkpoint start fresh), and both gates
re-run. Keep every batch's shards — training replays the accumulated set so new
batches improve the model instead of teaching it to forget. Per-user adaptation
enters the same way later, from the decision log (`outcome:` sources).

## Commands

One entry point (root `package.json`):

```sh
pnpm tyger bench    # selfcheck + product metrics + decision gate (the numbers)
pnpm tyger build    # train the student + export ONNX / CoreML / Core AI tiers
pnpm tyger clean    # remove bench-results/ (gitignored scratch; insights live in docs/)
```

`build` reproduces the student byte-exact (seeded) and copies the tracked
`student.traits.json` (the shipped thresholds — **0.85/0.4/0.4**; `ep_thr` is
live-call calibrated, `bench-results/live-calibration.md`) into place, so
`clean` is always safe. Featurizing shards is the
only slow step and lives behind `featurize.py` directly:

```sh
# env (once):
cd ports/tyger-student && uv venv .venv --python 3.12 && \
  uv pip install --python .venv/bin/python torch transformers datasets numpy

# synthetic smoke (torch + numpy only):
uv run --no-project --with torch --with numpy -- python ports/tyger-student/train.py --selfcheck

# shards from real conversations (teacher on MPS, ~4 min per 3-min session):
.venv/bin/python ports/tyger-student/featurize.py --split train --sessions 6 --out bench-results/student-shards/train
.venv/bin/python ports/tyger-student/featurize.py --split val   --sessions 2 --out bench-results/student-shards/val

# train + score gates, then the decision gate:
.venv/bin/python ports/tyger-student/train.py --shards bench-results/student-shards/train \
  --val bench-results/student-shards/val --out bench-results/student
.venv/bin/python ports/tyger-student/gate.py --shards bench-results/student-shards/val \
  --student bench-results/student/student.pt
```

## Shortcuts (deliberate, in-code)

- Training windows are 20 s with GRU state reset between them (see `train.py:windows`).
- `featurize.py` defaults to 3 min per session — stand-up scale; widen
  `--minutes`/`--sessions` before trusting gates.
- Gates on corpus-labeled heads are report-only until run 1 sets the bar.
- Judge on decisions + harness metrics too (`scripts/tyger-eval.py` sweeps: endpoint
  latency/early/miss, barge catch/false, bc precision/recall) — not score drift alone.
