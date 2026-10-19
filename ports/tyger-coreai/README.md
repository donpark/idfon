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
