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
| `train_shared.py` | the epic-#132 P2 weighted multi-teacher baseline: one `SharedLatentStudent` over one shard set per tap adapter, per-axis teacher weights from the P0 probe R2 (`--weights auto\|uniform\|FILE`), per-tap gate report (`--selfcheck`) |
| `checkpoint.py` | `student.pt` I/O for both models + the tap-binding shim (`TapBound`) so gate/harness/calibrate replay shared checkpoints like `Student` |
| `calibrate.py` | per-model fit of the rules' threshold knobs (ep/barge/bc) → `<student>.traits.json`; reports default AND calibrated agreement |
| `gate.py` | the decision gate: student's own events vs the teacher's, replayed with live rules feedback (parity7 metric, ≥99% PASS) |
| `export.py` | the size rung: `student.pt` → ONNX (`StudentStep{,Int8}.onnx`, TygerStep I/O contract) + parity gates (fp32 ≤ 1e-4, int8 probs ≤ 2e-3, decision-flip counts) |
| `export_coreml.py` | the apps' pre-27 tier: `StudentStep.mlpackage` (fp32, ANE-fp16-exempt by ruling) + carried-state parity |
| `export_coreai.py` | the apps' OS-27 tier: `student_step_float32.aimodel` + AOT `.aimodelc` container (loader-enforced; source loads leak ANE compiles) + coreai.runtime gate; `convert()` is the reusable half the matrix calls |
| `export_mlx.py` | the mac tier: `StudentStep{,Int8}.safetensors` — int8 per-output-unit group-16 storage, dequantised at load (the grid QAT projects onto, `quantize_step.py`'s `quantize()`) + carried-state parity |
| `runners.py` | one step-runner per tier (`onnx`/`coreml`/`coreai`/`mlx` + the torch reference): `step(hu, ha, act_db, prev_state, state) -> (out8, state)` — the surface the matrix gate and TurnShadow both replay through, plus artifact bytes, per-frame ms with a contention stamp, and AOT loadability (MPSGraph version, #110) |
| `export_matrix.py` | **P7**: the full matrix (every adapter × 4 tiers × {int8, fp32}) — exports, the P4 gate per cell, bytes, per-frame ms, exports-vs-loads → `bench-results/matrix/matrix.json` + `matrix.md` (`--selfcheck`, `--remeasure`) |
| `turnshadow.py` | **P7**: the swap-over gate — a candidate tier vs the authoritative fp32 student on recorded sessions, per-axis drift + decision flips + latency delta, fail-open (a tier that cannot load is reported, never fatal) |
| `harness.py` | the product-metric gate (the P1 brief's judgment): endpoint latency/early/miss, barge catch/false, bc precision/recall — teacher vs student on the same axes (`scripts/tyger-eval.py` definitions; proposed bars in `bench-results/harness-gate.md`) |
| `oracle.py` | the tyger-s2s seam (reference chain + rules + Mimi decode), one env contract |
| `probe.py` | the tap probe survey (#132 P0): per-tap ridge probes (R²/cosine) of the teacher's 8-vector per decision axis, held-out sessions; the tap-quality table that drives the per-axis adapter loss weights (`bench-results/tap-probes.md`, findings in `docs/voice-decision-model.md` P2) |
| `featurize_tap.py` | rebuild a shard set's `hu`/`ha` from the streaming (cache-aware) encoder tap or the windowed re-encode at any layer — keeps the teacher's 8-vectors/events/labels; the tap shard builder (`tap4-shards`, `l4-shards`) |
| `featurize_parakeet.py` | the P5 second-ASR tap builder: `nvidia/parakeet-unified-en-0.6b` per-layer taps on the teacher's frames (same contract as `featurize_tap.py`; one full-context pass per channel extracts all 24 layers — fp32 `--layer` master for training + fp16 per-depth `--sweep` sets for probe.py). Grid measured exact (burst train, row k = k·80 ms); runs in `.venv-nemo` |
| `agreement.py` | cross-geometry decision agreement (epic #132 P5): two students replayed on the same sessions through the same live rules feedback — A vs teacher, B vs teacher, A vs B (interchangeability behind the seam); per-side traits/temperature knobs |
| `test_model.py` | the shipped checkpoint-layout pin (student.pt loads by name) + the shared-latent seam smoke |
| `slow_state.py` | P6 (#160) serializer: fast-tier latent `z` + seam scores + energy/floor/mode over a trailing 2 s window, at deterministic clause/turn events (VAD transitions + fast candidates) → stackable `.npz` state + `events.jsonl`; the record shape lives here too |
| `slow_model.py` | P6 decoder shapes: `z-gru` (cheap heads over `z` history) and `state-transformer` / `-large` (decision model over the serialized per-frame state) |
| `slow_train.py` | P6 train/eval: teacher frame agreement, `commit` judgment AUC, per-domain (corpus + live LOSO) calibration, CPU latency and bytes; `--latency-only` |

## The slow tier (P6, #160)

Off the 80 ms frame path: at a clause/turn event, serialize a trailing 2 s window
of the fast tier's shared latent `z` plus the signals the fast tier already has,
then decode `docs/voice-decisions.md`'s record (`turn_state` choice, four `noul`
answers, `decision_confidence` score). The record is a pure function of the
serialized state — replayable, no hidden live session state.

Measured verdict (`docs/voice-decision-model.md` P6): the cheap `z-gru` decoder
(0.60 MB fp32 / 0.15 MB int8, ~0.24 ms CPU/event) carries the slow tier's
judgment (`commit` AUC .825 vs the fast seam's .743; .714 vs .600 at pauses) and
beats the serialized-state transformer at every measured seed; the large rung
only ties it at 8.8 MB. The slow tier does **not** replace the fast seam's frame
answers (endpoint agreement is ~1.4 pts below it) — it adds a judgment field.

```sh
.venv/bin/python ports/tyger-student/slow_state.py --shards bench-results/tap4-shards/train \
    --out bench-results/slow/train --student bench-results/shared-consistent-l03/student.pt --tap l4-streaming
.venv/bin/python ports/tyger-student/slow_train.py --train bench-results/slow/train \
    --val bench-results/slow/val --live bench-results/slow/live --out bench-results/slow --seed 0
```

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
  unwired), `parakeet-l12-full` (the second ASR, #132 P5). `kind: "aux"` is
  reserved for auxiliary-signal adapters (#131).
- **One shared causal latent `z`** (width-256 2-layer GRU over the summed fuse
  inputs) and **one decoder** (out_norm + registry heads) behind the unchanged
  8-vector seam. Every adapter trains toward the same decision endpoint; deploy
  exactly one adapter — the tap the streaming ASR already computes.
- Cross-adapter calls on the same frames are the P3 consistency-loss surface
  (KL between decisions via tap A and tap B). Per-axis teacher weighting (P2)
  comes from `probe.py`'s tap-quality table, never from averaged teachers —
  implemented by `train_shared.py` (baseline + formula live there).
- The existing `Student` is untouched — its checkpoint layout is pinned by
  `test_model.py` (the shipped tiers load by name).

### Second-ASR portability (epic #132 P5)

A new ASR joins the shared geometry with **an adapter + a calibration fit only** —
nothing behind the seam is re-tuned (`train_shared.py --adapter-only TAP` freezes
the latent + decoder + heads; `calibrate.py` fits that adapter's temperature and
threshold knobs; `agreement.py` measures the decisions).

- **The pick:** `nvidia/parakeet-unified-en-0.6b` (Unified-FastConformer-RNNT,
  24×1024-d, x8 subsampling = the 80 ms decision grid; NVIDIA Open Model License).
  Genuinely different family from the Nemotron streaming ASR; unified streaming+offline
  in one checkpoint. NeMo runs on macOS/MPS for encoder taps (RNNT decode does not —
  taps are all we need): `uv venv .venv-nemo` + `pip install nemo_toolkit[asr]`.
- **Tap equivalents are measured, not numbered:** the per-depth probe sweep
  (`bench-results/parakeet-tap-probes.md`, 68 sessions, same split convention as
  `tap-probes.md`) peaks **mid-encoder (L9–L13)** — depth fraction does not port.
  L12 wins the probe mean (.554 vs the Nemotron `l4-streaming` .564, `l15-windowed`
  .632); bc is the weak axis everywhere (.390 max @L6 vs .457 @L15 Nemotron).
- **Result (adapter-only through the frozen λ=0.3 geometry):** seam head MSEs
  .0086/.0050/.0027/.0071 pass the universal gates; endpoint .02435 sits between
  the Nemotron L4 taps (.02299/.02564) under the same tap-bounded .028 ceiling
  (`ADAPTER_GATE`). Agreement vs teacher 52.10% → **56.84% calibrated** (T=0.7,
  0.93/0.5/0.4). Cross-geometry vs the Nemotron path: **61.0% raw / 67.7%
  calibrated** — at product config the paths agree with each other at parity with
  the Nemotron path's own teacher agreement (67.85%). Harness vs teacher:
  endpoint latency −0.05 s, early +2 / miss +1 of 44, false barges 7 vs 31 (−24),
  bc recall −.06 (the known weak axis).
- **Budget:** a new ASR costs one adapter (525 K params, 2.0 MB fp32 inside the
  5.3 MB single-adapter artifact) + a ~200 B traits fit + tap extraction
  (~15 s per 3-min session; encoder pass 0.3 s on MPS). Per-frame step cost is
  unchanged (the adapter is two 1024→256 projections).
- **Shortcuts:** full-context taps (`featurize_parakeet.py` — the cache-aware
  streaming pass drift is unmeasured, measure before any P7 swap-over);
  corpus-domain calibration only (a live-domain fit needs a `--wavs` path in
  `featurize_parakeet.py`); calibrated A↔B replayed per-side traits but one shared
  debounce triplet (both sides fit 2/2/2 anyway).

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
6. **Export** (done — all four delivery tiers, all gated):
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
   - MLX (`export_mlx.py`): `StudentStep.safetensors` fp32 and
     `StudentStepInt8.safetensors` (group-16 storage) — the macOS 14–26 step tier;
     parity vs torch on carried-state frames (`--shards`).
   **QAT is not needed for the single-tap student** (every gate passes post-training);
   the shared-latent tier does need it (#145: off-grid int8 drifts 3–6e-3), which is why
   the matrix's int8 source is the QAT fine-tune. Env note: coreai-models
   installs from `~/dev/coreai-models/python` (the `~/dev/github/coreai-models`
   checkout is stale and its converter crashes on fused LayerNorm locs).

## The P7 matrix and the swap-over gate (#161)

Four tiers, one gate. `export_matrix.py` covers every adapter the converged int8
checkpoint carries × ONNX / Core ML / Core AI / MLX × {`int8`, `fp32`}, gates each cell
with P4's envelope against the cell's own torch source, and records **exports** and
**loads** as separate facts (a Core AI AOT container above MPSGraph 7.0.80 does not
load on the 27.0.x runtimes — #110). `turnshadow.py` then diffs every loadable cell
against the authoritative fp32 student on recorded sessions: per-axis drift, decision
flips, per-frame ms. Shadow only — classic stays the fail-open path.

```sh
PY=ports/tyger-student/.venv/bin/python; M=/Users/don/dev/idfon/bench-results
# the int8 source: the #145 QAT fine-tune (converge in fp32, then adapt to the grid)
$PY ports/tyger-student/train_shared.py --tap l15-windowed=$M/student-shards \
    --tap l4-windowed=$M/l4-shards --tap l4-streaming=$M/tap4-shards \
    --out bench-results/shared-qat-ft --epochs 20 --lr 1e-4 --seed 0 \
    --consistency 0.3 --qat 16 --init $M/shared-consistent-l03/student.pt
# the matrix (+ the per-adapter calibration artifacts, traits.json per adapter)
$PY ports/tyger-student/export_matrix.py --student bench-results/shared-qat-ft/student.pt \
    --fp32 $M/shared-consistent-l03/student.pt --shard-root $M
# the swap-over gate
$PY ports/tyger-student/turnshadow.py --matrix bench-results/matrix \
    --fp32 $M/shared-consistent-l03/student.pt --sessions 2 --frames 500
# re-time the same artifacts on a quiet machine (latency, no re-export)
$PY ports/tyger-student/export_matrix.py --out bench-results/matrix --remeasure
```

Adding a tap (a new ASR) adds an adapter row, not a new pipeline: train the adapter
(`train_shared.py --adapter-only TAP`), fit it (`calibrate.py --tap`), then re-run the
matrix with `--shards TAP=<tap-shards>`. The swappable-checkpoint boundary is stated in
`docs/voice-tyger-ondevice.md` ("Export matrix and the swap-over gate").

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
