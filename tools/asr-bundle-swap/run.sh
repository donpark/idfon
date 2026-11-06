#!/usr/bin/env bash
# Every number in docs/voice-tyger-ondevice.md § "What the ASR bundle swap
# changes". Run from the repo root; artifacts land in the gitignored bench-results.
#
#   1. download the 3.5 multilingual bundle (multilingual/560ms, 664 MB)
#   2. stage our 42/13 encoder into a copy of it (prompt_id stays a model input)
#   3. build the probe
#   4. same three live calls through: shipping English, multilingual, staged
#   5. the multilingual bundle again on its own default prompt (auto=101)
#   6. transcripts side by side, word-level divergence, partial cadence
#
# The shipping English bundle is already on disk (~/.idfon/models/..., 597 MB)
# because the app downloaded it; nothing re-fetches it. Nothing is overwritten:
# the staged dir is its own directory, the bundle is only read.
set -euo pipefail
cd "$(dirname "$0")/../.."

# A worktree has no venv of its own; pass the main checkout's (coremltools).
PY=${PY:-ports/tyger-student/.venv/bin/python}
OUT=${OUT:-bench-results/asr-bundle-swap}
EN=${EN:-$HOME/.idfon/models/nemotron-streaming/560ms}
ENCODER=${ENCODER:-/Users/don/dev/idfon/bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage}
SESSIONS=${SESSIONS:-2026-10-25T23:13:14Z:1394,2026-10-26T20:17:43Z:1114,2026-10-26T21:13:38Z:1891}
BIN=tools/asr-bundle-swap/.build/release/asr-bundle-swap
ML=$OUT/hf/multilingual/560ms
STAGED=$OUT/models/staged-560ms

if [ ! -f "$ML/metadata.json" ]; then
  hf download FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML \
    --include "multilingual/560ms/*" --local-dir "$OUT/hf"
fi
if [ ! -d "$STAGED/encoder.mlmodelc" ]; then
  $PY tools/asr-bundle-swap/stage_models.py \
    --bundle "$ML" --encoder "$ENCODER" --out "$STAGED" --verify
fi

swift build -c release --package-path tools/asr-bundle-swap
$BIN --selfcheck

$BIN --en "$EN" --ml "$ML" --staged "$STAGED" --language en-US \
  --sessions "$SESSIONS" --out "$OUT/transcripts.json"
# Distinct label: both runs are the same model, two prompt values.
$BIN --ml "$ML" --language auto --label ml-auto \
  --sessions "$SESSIONS" --out "$OUT/transcripts-auto.json"

python3 tools/asr-bundle-swap/diff.py --selfcheck
python3 tools/asr-bundle-swap/diff.py "$OUT/transcripts.json" "$OUT/transcripts-auto.json"
