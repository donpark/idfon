#!/bin/sh
set -eu

# P1 no-network pipeline check (epic #17): text -> PCM -> WAV through the
# stub VoiceEngine, with no credentials and no provider process. Fails if the
# seam no longer compiles/runs offline or the WAV is malformed.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

work=$(mktemp -d "${TMPDIR:-/tmp}/idfon-voice-pipeline.XXXXXX")
trap 'rm -rf "$work"' EXIT

# --offline guarantees the check never reaches the network.
out=$(cargo run --offline --quiet -p idfon-voice --example pipeline -- \
  "$work/pipeline.wav" "There are 42 yen left.")
echo "$out"
# The native G2P front end (P6) speaks written numbers as words.
printf '%s\n' "$out" | grep -q 'normalized=There are forty-two yen left.' \
  || { echo "FAIL: G2P did not normalize the number" >&2; exit 1; }

python3 - "$work/pipeline.wav" <<'PY'
import sys
import wave

path = sys.argv[1]
with wave.open(path, "rb") as audio:
    assert audio.getframerate() == 24000, audio.getframerate()
    assert audio.getnchannels() == 1, audio.getnchannels()
    assert audio.getsampwidth() == 2, audio.getsampwidth()
    frames = audio.getnframes()
    assert frames > 0, "pipeline produced no audio"
    samples = audio.readframes(frames)
    assert not any(samples), "stub engine must emit silence"
print(f"PASS: offline voice pipeline produced {frames} frames of 24 kHz mono s16 WAV")
PY
