# tyger-coreai

Core AI port of the turn chain (the OS 27+ voice tier; docs/voice-tyger-ondevice.md).
Exports `.aimodel` bundles via Apple's `coreai-torch` bridge and gates them on
this Mac with `coreai.runtime` (cpu/gpu).

## Environment (python 3.12 — see gotchas)

    uv venv --python 3.12 .venv
    uv pip install --python .venv \
        coreai-core==1.0.0b3 coreai-torch==0.4.3 \
        "coreai-opt @ https://files.pythonhosted.org/packages/c1/1a/db40b025a5469a33b28d04a984d1ce78eef0b0ceea31b31abcbc4a97d69c/coreai_opt-0.2.0-py3-none-any.whl" \
        torch numpy safetensors huggingface_hub transformers sentencepiece tokenizers \
        accelerate tqdm rich diffusers librosa
    uv pip install --python .venv --no-deps -e ~/dev/coreai-models   # apple checkout

Smoke: `.venv/bin/python smoke.py` — tiny model through export -> .aimodel ->
runtime -> torch comparison (expect max|Δ| = 0.0).

## Gotchas (2026-10-19)

- **Python 3.12.** coreai-opt 0.2.0 requires <3.14; coreai-core 1.0.0b1 macOS
  wheels are cp311/cp312 only; coreai-models' PyPI stub wants >=3.14 (ignore it
  — install the checkout with --no-deps).
- **coreai-core 1.0.0b1 + coreai-torch 0.4.0 (apple's pin) CRASHES** here with
  `LLVM ERROR: cannot unwrap empty odiec_module_t` / "expected AICode versioned
  location" during Linear conversion — emitter/compiler skew. b3 + 0.4.3 works.
- b3 API: `AIProgram.save_asset(Path, metadata, minimum_os=OSVersion.v27)`;
  there is **no `optimize()`** any more (the zoo's scripts call it — that's the
  b1 API). `AIProgram` lives in `coreai.authoring.asset`.
- coreai-opt has no index entry for this interpreter — install the wheel by
  direct URL (from apple/coreai-models' uv.lock).
- `xcrun coreai-build compile` does the AOT device build (Metal toolchain
  component: `xcodebuild -downloadComponent MetalToolchain`).

## Export facts (2026-10-19, export_turn.py)

- `reference_inputs` keys must match `forward`'s parameter names; `input_names`
  renames the graph's external I/O (use long descriptive names).
- Dynamic shapes work: `dynamic_shapes={"feats": {1: 8*Dim("_mel",5,101)-7}}`
  exports the startup contract (true growing windows) in one asset.
- **transformers 5.20.1** is required (the bundle's `nemotron3_5_asr` arch).
- Gates: step exact on GPU (max|Δ| 0.0); encoder ~1e-4 (cos 1.0) on both GPU
  and CPU, real fixture audio.
- **CPU specialization fails on the big step graph** (`AIModel.load` with
  `cpu_only` errors; GPU loads fine). Gate on GPU; per-unit load failures are
  reported as SKIP.
- **ANE compiler internal error** appears at load of the dynamic-shape encoder
  ("Plist name mapping doesn't contain name: ..._constin_liveout_dummy_pool",
  ANECCompile code 22) and falls back to GPU. The NE path is not usable for
  this graph yet — same posture as the zoo's diarization gate (NE below bar →
  ship GPU).

## Compiled containers and disk hygiene (2026-10-27)

- `export_turn.py` AOT-compiles each export into `<name>.compiled.aimodel/`
  with a scoped `--architecture` (default: this Mac's token, read from an
  existing container). NEVER run `coreai-build compile` without
  `--architecture`: it builds every supported arch (22 for macOS, 9 for iOS)
  and each arch child copies the weights (~50 MB per arch for the step,
  ~787 MB for the encoder). Ruling: compile for macOS and iOS targets only,
  and add archs as devices are confirmed.
- Loading a source `.aimodel` makes the runtime attempt an ANE compile per
  process: one `mpsgraph-*` workdir under
  `$TMPDIR/com.apple.MetalPerformanceShadersGraph/`, plus a feed to the daemon
  ANE caches (`/Library/Caches/com.apple.aned` and friends — datavault-locked;
  only a reboot flushes them; the recurring ~300 GB "System Data" balloon).
  The Swift loaders avoid this via the compiled containers. The Python binding
  cannot load `.aimodelc` (coreai-core 1.0.0b3, verified 2026-10-27) and
  specialization options change nothing about the attempt (numerics identical
  with and without options, max|Δ| 0.0), so every harness process pays one
  compile attempt per model load: run suites in few processes, and sweep
  scratch after (the export pipeline does both).
- `scripts/coreai-cache-prune.sh` removes stale registrations in
  `~/Library/Caches/coreai-cache`. Judge the reclaim by df deltas, never by du.
- Or run `pnpm ane list` / `pnpm ane clean` — the same leftovers for humans and
  agents (contract in `docs/disk-hygiene.md`).
