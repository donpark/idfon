# tyger-onnx — the decision model as ONNX, for the eve TS agent

The `nineninesix/tyger` turn-taker (encoder + GRU + heads) exported to ONNX and
gated against the torch oracle, so `integrations/eve-idfon-voice/src/tyger/` can
run the model **in-process in Node** (onnxruntime-node) — no Python in the
product loop. The tyger-s2s stack stays as the reference oracle.

Consumer docs: `docs/voice-tyger-option.md` (classic vs tyger as product
options). The on-device tiers are `ports/tyger-{coreml,coreai,mlx,swift}`.

## Artifacts (bench-results/onnx/, gitignored; regenerable)

| File | What | I/O |
| --- | --- | --- |
| `TygerStep.onnx` (+`.data`, 56 MB) | the 14M GRU turn-taker (fp32 reference) | hu/ha (1,1,1024) + act_db + prev_state (i64) + state (3,1,768) → out (1,1,8) + state. `act_db` normalization `((db+50)/25).clamp(-3,3)` is baked in (head_step semantics) |
| `TygerStepInt8.onnx` (+`.data`, 23 MB) | the same turn-taker, P0 size cut (`quantize_step.py`): GRU + fuse weights int8 group-16, heads/norms/emb fp32, dequantized in-graph (compute stays fp32) | identical I/O |
| `TygerEncoderDyn.onnx` (+`.data`, 1.53 GB) | the Nemotron ASR encoder **truncated at L15** (~383M params: front 5.1M + layers-to-L15 378M — the heads read L15 only), masked + dynamic | mel (1,T,128) + mask (1,T) → hidden L15 (1,T',1024); **mel lengths are 8k−7** (33, 41, …, 801) |
| `TygerEncoder.onnx` (1.53 GB) | static 801-mel encoder (superseded by Dyn for the engine) | mel (1,801,128) → hidden |
| `step-oracle.json`, `enc-oracle.json` | oracle pairs for the gates | |

## Regenerate + gate

```sh
# venv: the tyger-s2s venv (torch + onnxscript; see the patch note below)
TYGER_S2S=~/dev/tyger-s2s ~/dev/tyger-s2s/.venv/bin/python ports/tyger-onnx/export_step.py --dyn
node ports/tyger-onnx/step-parity.mjs      # step 7.7e-6 / state 6.1e-6 (gate 1e-4)
node ports/tyger-onnx/engine-parity.mjs    # composed chain 1.4e-5 over 248 frames (gate 1e-4 step / 1e-3 encoder)
```

Measured (2026-10-20, Apple Silicon): step **7.7e-6** out / **6.1e-6** state;
encoder **1.68e-4** hidden (fp32 reassociation over 24 layers; the decision
outputs are the contract); composed chain (TS mel → ONNX encoder → ONNX step,
state threaded) **1.434e-5** over 248 frames / 62 hops at **163 ms/hop CPU**
(hop budget: 320 ms).

## P0: the int8 step (the size cut, 2026-10-31)

`docs/voice-decision-model.md` — the shipped decision model should not be 56 MB.

```sh
uv run --with onnx --with numpy python ports/tyger-onnx/quantize_step.py   # -> TygerStepInt8.onnx
node ports/tyger-onnx/qstep-parity.mjs                                     # the gate
```

Gate = per-head max|Δ| vs the fp32 reference ≤ 0.02 on the 4 probs (S3
envelope) + identical rules decisions (±2 frames) + no state-decision flips,
over the runtime fixture. Measured: probs **1.2e-3 … 2.0e-3** (p_end worst,
10× inside), decisions identical, 0/248 flips; **56 MB → 23.2 MB**.

- Per-row grouping (`--group 0`, 19.5 MB) **fails** `p_end` at 2.0e-2 — the
  endpoint head pays for crude quantization first, reproduced from the S3 MLX
  study. Group-16 is the shipped layout; `--gru-only` keeps the fuse fp32.
- Drift is ~10× smaller than the encoder-quantization floors (0.030–0.041 on
  `p_end`) — quantizing the turn-taker is safe where quantizing the encoder is not.
- Memory at runtime is unchanged (ORT materializes the fp32 weights); this is a
  shipped-bytes cut. The P1 student (`docs/voice-decision-model.md`) is the
  real fix for both.

## Corpus decision gate (the overnight one)

```sh
TYGER_S2S=~/dev/tyger-s2s ~/dev/tyger-s2s/.venv/bin/python ports/tyger-onnx/sessions-prep.py
node ports/tyger-onnx/decision-parity.mjs
```

24 val sessions × 3 min of `anyreach-ai/dualturn-otospeech-turn-taking` (Mimi
codes → 16 kHz wavs) vs the fp32 oracle's events (from
`ports/tyger-coreml/parity7.py --cand coreai --dump`, extracted by the prep).
Result: **99.89% decision agreement (916/917, ±2 frames), 99.24% same-frame** —
one backchannel flip at a 0.50 threshold boundary. Note the corpus is
codec-round-tripped audio and `license: other` (internal evaluation only).

## Bundle (what the agent loads)

```sh
node ports/tyger-onnx/pack-bundle.mjs   # -> ~/.idfon/models/tyger/ + manifest.json (sha256 per file)
```

Prefers `TygerStepInt8.onnx` when present (packed as the step; `bundle.ts`'s
`stepPath` follows), else the fp32 pair.

`integrations/eve-idfon-voice/src/tyger/bundle.ts` verifies every byte before
use (`IDFON_TYGER_BUNDLE` overrides the location). `manifest.url_base` is the
seam for a download host when we have one.

## Export landmines (each cost a debugging round)

- **The dynamic export needs a transformers patch** in the tyger-s2s venv:
  `modeling_nemotron_asr_streaming.py`'s attention head-merge
  `attn_output.reshape(...)` after transpose must become
  `attn_output.clone(memory_format=torch.contiguous_format).reshape(...)`.
  `torch.export`'s fake kernel refuses the transposed view; `contiguous()` is
  *elided* in decomposition; plain `clone()` preserves transposed strides.
- The legacy exporter (`dynamo=False`) is fine for **static** shapes only: its
  `dynamic_axes` freezes shape-derived mask constants ("broadcast 5 by 13" at runtime).
- Weights export to external `.onnx.data` next to the graph; the parity scripts
  resolve `onnxruntime-node` through the **integration package's** install — a
  second install gives a different `Tensor` class and `session.run` rejects it
  ("Tensor.location must be a string").
- The oracle dumps must call the same wrapper the export used (`StepWrap`,
  normalization baked in) — a parallel path feeding raw `act_db` yields O(1) diffs.

## E2E (WIP)

`live-relay-e2e.mjs` — a fake bridge + `say`-generated caller audio driving the
whole relay loop (tyger endpoint → STT → reply → TTS). Written, not yet green
(URL-construction bug in its setup), and deferred per the on-device push.
