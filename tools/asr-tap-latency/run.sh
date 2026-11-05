#!/usr/bin/env bash
# Every number in docs/voice-tyger-ondevice.md § "Tap delivery through the real
# manager". Run from the repo root; artifacts land in the gitignored bench-results.
#
#   1. stage the model dir (tap encoder + shipping decoder/joint/tokenizer)
#   2. the onset calibration (frame-to-audio alignment, measured not assumed)
#   3. unpaced: arithmetic only (the offline harness's virtual clock, real manager)
#   4. paced: a device clock, the product number
#   5. two controls: no hook (what the hook path costs), 320-frame buffers
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN=tools/asr-tap-latency/.build/release/asr-tap-latency
OUT=${OUT:-bench-results/asr-manager-probe}
MODELS=$OUT/models/560ms
TAP=${TAP:-/Users/don/.t3/worktrees/idfon/t3-c712c420/bench-results/asr-tap-fixed/encoder_tap_42-13_fp16_int8w.mlpackage}
# Same three live-shipping sessions the offline harness replayed; frame counts are
# the shards' T (the captures are a few frames longer than the shard).
SESSIONS=2026-10-25T23:13:14Z:1394,2026-10-26T20:17:43Z:1114,2026-10-26T21:13:38Z:1891
ONE=2026-10-26T20:17:43Z:1114

if [ ! -d "$MODELS" ]; then
  ports/tyger-student/.venv/bin/python tools/asr-tap-latency/stage_models.py \
    --tap "$TAP" --out "$MODELS" --verify
fi
swift build -c release --package-path tools/asr-tap-latency

$BIN --models "$MODELS" --onset --out "$OUT/onset.json"
$BIN --models "$MODELS" --sessions "$SESSIONS" --modes unpaced --out "$OUT/unpaced.json"
$BIN --models "$MODELS" --sessions "$SESSIONS" --modes paced --out "$OUT/paced.json"
$BIN --models "$MODELS" --sessions "$ONE" --modes paced --no-callback --out "$OUT/nohook.json"
$BIN --models "$MODELS" --sessions "$ONE" --modes paced --buffer-frames 320 --out "$OUT/buffer320.json"
