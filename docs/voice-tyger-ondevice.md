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
