---
name: "coreml-ane-precision"
description: "Precision and quantization playbook for on-device models on Core ML / Apple Neural Engine, Core AI (.aimodel), and the MLX comparison tier. Use when converting models to CoreML or Core AI, debugging fp16 or quantization drift, choosing compute precision or quantization configs, measuring model parity against a reference, gating a converted bundle, or explaining why a decision layer flips near its threshold. Covers the known ANE fp16 op-defect family, the exemption/mixed-precision pattern, on-device loader landmines, and idfon's parity harnesses (parity6/parity7)."
version: 1
created: "2026-10-19"
updated: "2026-10-19"
---
# Core ML / ANE precision

## The problem shape

A "small" score drift is not one thing. Separate three layers:

1. **Wiring bugs are O(1).** Wrong weights, wrong transpose, wrong axis, wrong
   frame alignment — outputs are visibly wrong (logits off by units). Diagnose
   with stage-by-stage dumps against the reference chain before touching
   precision (see "Bisect method").
2. **Lossy-tier drift is small and structured.** Same order every frame, worst
   on the calibration-sensitive heads, always located AT decision thresholds
   when it changes behavior. Shrink the drift and the *rate* of decision flips
   shrinks; it never reaches zero (thresholds sitting exactly at 0.5 flip under
   any arithmetic difference).
3. **Converter bugs are op-specific.** The converter sometimes emits
   mathematically correct but numerically naive formulations that overflow or
   underflow in fp16 on ANE (below). These are fixable and worth identifying —
   they look like "fp16 is bad" but are really "this op is broken in fp16".

## The known ANE fp16 op-defect family (upstream)

A systematic audit found ops whose fp16 form overflows/underflows via `exp()`
intermediates (apple/coremltools PRs #2725–#2727, issues #2687, #2690, #2728,
#2729):

| Op | Failure on ANE in fp16 | Stable alternative |
|---|---|---|
| softplus `log(1+exp(x))` | overflows at x ≈ 10.4 (drops to 0) | `max(x,0)+log(1+exp(-|x|))` |
| mish | same overflow class | same decomposition |
| logsumexp | hard overflow at x ≈ 7.63 (C=32) | max-shift decomposition |
| log_softmax | `-inf` when one class dominates | max-shift |
| logcumsumexp | overflow for inputs > ~11.09 | max-shift |

Related per-op defects on record: `rms_norm` translation inflates eps by
`max(|x|)^2` (issue #2821 — percent-level errors even at FLOAT32/CPU_ONLY;
layer_norm may be fine, verify per model); fp16 mlprogram can hang at load with
compute_units=ALL (#2660); MobileNetV3-class large FP16 errors (#2625); GPU
fused-SDPA wrong for batch ≥ 10 (#2650). Audit tool referenced upstream:
`ane-fp16-lint` (github.com/Ashutosh0x/ane-fp16-lint).

**Rule: grep the exported graph for softplus/mish/logsumexp/log_softmax/
logcumsumexp before believing any fp16 result.** Our encoder uses softmax (not
log_softmax), sigmoid, silu, layernorm, tanh — outside the known five, which is
why our fp16 drift reads as accumulation, not overflow.

## The mitigation playbook (maintainer-confirmed, issue #2603)

1. **Keep precision-sensitive layers in FLOAT32** and let the rest run fp16.
   The converter's guidance: identify the discrepant layers with
   `MLModelComparator`
   (apple.github.io/coremltools/docs-guides/source/mlmodel-debugging-perf-utilities.html#mlmodelcomparator),
   run it with `compute_units=CPU_ONLY`, retain those layers in Float32.
2. **ANE only runs fp16** — a "fp32 op" falls back to CPU/GPU. That is fine and
   cheap if the fp32 part is small (our stem+layers.0 front is 0.12 GB; the
   startup encoder already runs CPU_ONLY; budgets are huge vs measured cost).
3. **Quantization layouts are not portable across frameworks.** Core ML's
   `OpLinearQuantizerConfig` (per_block / per_channel / block) cannot express
   per-output-unit group-16 ASYMMETRIC along the contraction axis — the exact
   config that passes in MLX. Do not assume a winning config transfers.
4. **Per-op precision/quantization**: `op_name_configs`, `ct.optimize.*`,
   split export (below) are the levers; `compute_precision=FLOAT16` is
   all-or-nothing.

## What idfon measured (the evidence table)

Reference = torch fp32 oracle; drift = max/mean per-head delta of the 8-vector
(4 state logits, hazard, yield, bc, ep). Score budget = 0.02; acceptance = rule
decision agreement.

| Config | state logits | verdict |
|---|---|---|
| CoreML FLOAT16, everything | 0.53–0.62 | fails budget; decision guard at 60 s ok, **fails at 72 min (95.9% vs 99%)** |
| CoreML Q8 per-block-16, everything | 0.63 | fails |
| CoreML split: fp32 front + Q8 tail | 0.145 | fails (ep floor 0.03–0.04) |
| MLX int8-g16, no exemptions | ~0.9 (symmetric 64-groups variant) | fails |
| **MLX int8-g16 asymmetric, stem+layers.0 fp32** | **0.007** | **only config ever passing ≤0.02** |

Convergent lesson from every run: **the exemptions are the variable.**
Quantizing/derounding everything drifts the state heads; keeping the stem and
first block fp32 fixes them (and the apparent "ep floor" disappears with it —
it was not fundamental). Boundary flips remain at ~3 per 1000 decisions even
for the passing config.

**Never measured (the obvious next config): CoreML split front-fp32 (CPU) +
tail-fp16 (ANE)** — artifacts exist (`TygerFront`, `TygerTail`), only
front-fp32 + tail-Q8 was measured. This is the direct translation of the
passing MLX recipe and could recover ANE without the jitter.

### Core AI mixed-precision sweep (2026-10-27, negative result)

Gate = `scripts/corpus-corner.py` (margin turns whose fp32 p_end peaks at
0.94–0.96 against the 0.915+debounce bar). Every fp16-encoder config tried
produces ZERO endpoints — the wall is the encoder's fp16 tail, not the step:

| Core AI config | torch hidden drift (mean / max) | corner gate |
|---|---|---|
| encoder+step full fp16 | 0.015 / 0.35 | 0 endpoints |
| mixed: enc stem+block0 fp32, step GRU+heads fp32 | 0.005 / 0.28 | 0 endpoints |
| mixed encoder + fully fp32 step | (same encoder) | 0 endpoints |

The exported asset drifts MORE than torch math (max 0.875 through the runtime
vs 0.28 in torch; one region hits an ANECCompile internal error and falls
back — isolate before blaming precision). The MLX stem+layers.0 exemption
recipe does not transfer (consistent with "quantization layouts are not
portable across frameworks"). Remaining levers if fp16 must carry the margin:
much larger fp32 exemption (breaks the size budget), a rung-specific endpoint
threshold (product-tolerance question), per-stage bisect for an op defect.

## idfon's machinery (paths + commands)

- `ports/tyger-coreml/export.py` — `--only front|tail|check`; `--only enc-dyn`
  for the startup model (torch.export dynamic shapes; mel lengths must be
  `8k-7`; **must load `compute_units=CPU_ONLY`** — the rel_shift reshape fails
  MPS type inference). `--check` proves split == full at 0.0.
- `ports/tyger-coreml/quantize.py --granularity` — Core ML quantization knobs
  (per_block / per_channel / palettize8).
- `ports/tyger-coreml/parity6.py` — score budgets + decision guard on one
  session; `--startup` for growing windows; `--enc-front/--enc-tail` for the
  split compose.
- `ports/tyger-coreml/parity7.py` — scaled decision agreement (`--cand fp16|mlx`,
  `--dump` for margin analysis). Guards any tier swap.
- `ports/tyger-mlx/` — the accepted MLX chain (oracle for re-exports) and
  `export_swift.py` (bakes the accepted quantization to fp32 safetensors).
- Run env: `~/dev/tyger-s2s/.venv/bin/python` (homebrew python lacks
  coremltools/numpy).

## Analysis rules (learned the hard way)

- **Bisect method**: dump reference-chain stage outputs (mel → sub → block0 →
  final; fuse → heads → GRU cells) and compare per stage. Found an O(1) bug in
  ~4 iterations where end-to-end comparison showed only noise. Do this BEFORE
  any precision theorizing.
- Event comparison must be **time-aligned with frame indices** (same kind
  within ±tol); positional comparison turns one shifted event into a cascade.
  The margins probe: ep is head index 7 (4 is hazard).
- Interpret the margin analysis: if every flip sits at a threshold with
  probability delta ≈ the tier's drift envelope, the tier is behaving as
  characterized — the question becomes product tolerance, not correctness.
- Binding model I/O: bind by SHAPE (8 vs 3×768), not names — trace-generated
  names (`input_665`, `var_114`) change on re-export.

## MLX cross-tier notes

mlx-swift gotchas that masquerade as precision bugs: `transposed(0, 1)`
(variadic) silently did not transpose — use `transposed(axes: [1, 0])`;
`MLXArray([Double])` is float64 = GPU crash; `IntOrPair` params take array
literals (`stride: [2, 2]`); Xcode 26+ needs
`xcodebuild -downloadComponent MetalToolchain` before any Metal build.

## Core AI (.aimodel, iOS/macOS 27) — the successor runtime

Apple's on-device runtime after Core ML: PyTorch → `coreai-torch` → `.aimodel`
bundles on GPU or NE (`coreai.llm.export` for LLMs). SDK: CoreAIKit (chat/TTS
sessions, FoundationModels adapter). **The key reference collection is
`github.com/john-rocky/coreai-model-zoo`** (successor to CoreML-Models):
every model carries `models/<model>/recipe.toml`, is gated against its source
model before shipping, and the gate is re-runnable. Its `conversion/nemotron_asr/`
is a port of OUR exact encoder (streaming caches, 4-frame chunks, Swift mel
gate) — read it before any incremental/streaming work here.

### On-device loader landmines (from their port of our architecture)

- **>2 GB multi-I/O bundle**: AOT-compiles fine, on-device loader rejects it
  with an instant POSIX-2 ENOENT (bisected: 1- and 12-layer bundles of the
  same topology load; the trigger is the bundle size). Fix: split the network
  into weight-sharing halves (~1.1 GB each) at the cost of one extra graph
  call per chunk.
- **Input named `x` rejected**: the same graph loads when the input is renamed
  to a long descriptive name (`embeds`). Bisected on iPhone 17 Pro / iOS 27.
  Keep long descriptive I/O names.
- Recipe prerequisites have kinds (`overlay` / `needs` / `runtime` / `device`):
  an export that skips a `runtime` prerequisite still *succeeds*, and the
  bundle then misbehaves inside the app. Missing prerequisites must be named,
  not guessed.

### Gating methodology worth copying

- Two separate questions, two artifacts: "is the bundle *described* correctly"
  (zoo_verify: tokenizer/template/context/declared precision vs the source's
  metadata) vs "does the bundle still *compute* the right thing" (coreai_gate:
  rebuild the reference in fp32, compare greedy decode token-for-token).
  Never let one stand in for the other.
- **Publish gate transcripts**: pinned revision, exact inputs, both sides'
  outputs, tie margins, verdict. Rebuilding an oracle is expensive; re-running
  the engine side against a published transcript is cheap.
- **Conversion is not byte-deterministic** (same recipe twice → bundles differ
  byte-wise). Judge by gates, never by checksums.
- Gate ladder per model: eager fp32 per-chunk (embeds + caches + per-layer
  hidden vs oracle) → fp16 export → engine per-chunk cosine on cpu/gpu.
  Per-layer hidden-state dumps catch drift location, not just magnitude.
- **The PYTHON binding leaks ~1 IOSurface per inference call** (plain NDArray
  churn is fine, `fn(...)` calls are not; GC and model reloads don't release
  it; ~8–9k calls per process hits a fatal `NDArray+SharedStorage` allocation
  error). Harness fix: shard runs by process. **The Swift runtime does NOT
  leak: 30k calls in one process passed clean (CoreAISoakTests soak) — Python
  is the harness-only path.**
- **`SpecializationOptions.expectFrequentReshapes = true` CORRUPTS dynamic
  models' GPU execution** (max|Δ| ~10 on hidden vs the same asset in Python;
  exact with it off). Apple's own "dynamic models prefer GPU + frequent
  reshapes" guidance is wrong here — leave it off and verify per model.
- Acceptance bar for end-to-end ASR ports: token-exact vs oracle.

### Their streaming-cache design for our encoder (the S3 lever)

56-slot right-aligned rolling KV window per layer (steady state =
cache 56 + chunk 4 = 60 keys = the `chunked_limited` window, all visible;
early chunks masked via additive `-inf` neg_mask); conv2d caches = last
freq-padded time row per subsampling stage; conv1d caches = last 8 post-GLU
frames per layer; zero-init == HF zero-init. **Rel-pos distances are unchanged
by right-alignment**, so pos_emb is a fixed constant. Streaming mel contract
(their `gate_mel_swift_streaming.py` is the line-for-line spec for Swift):
frame t depends only on samples `[160t-200, 160t+200)` → emit as soon as
`160t+200` arrived; preemphasis is continuous across packet boundaries.

