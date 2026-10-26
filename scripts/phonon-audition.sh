#!/usr/bin/env bash
# Render the Phonon audition set (docs/voice-audition.html) and open the page.
#
#   scripts/phonon-audition.sh [OUTDIR] [PTTS]
#
# OUTDIR: where the wav files land (default ~/.cache/idfon/hum-audition).
# PTTS: a ptts CLI build (default: `ptts` on PATH). Build one from an xn-ptts
# checkout:  cargo build --release --bin ptts --features cli
# The audio is regenerable and stays out of git; the page is copied next to it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HOME/.cache/idfon/hum-audition}"
PTTS="${2:-ptts}"
command -v "$PTTS" >/dev/null 2>&1 || {
  echo "phonon-audition: ptts CLI not found. Build xn-ptts with --features cli and pass its path." >&2
  exit 2
}

mkdir -p "$OUT"
render() {
  "$PTTS" --lang en "$2" -o "$OUT/$1.wav" 2>/dev/null && echo "ok $1"
}

# Letter-string hums.
render mm-hmm "Mm-hmm."
render mhm "Mhm."
render hmm "Hmm."
render huh "Huh."
# Vowel sounds.
render um "Um."
render umm "Umm."
render uh "Uh."
render ah "Ah."
render oh "Oh."
render hmm-leadin "Hmm, let me check the time in Tokyo."
render um-leadin "Um, one moment."
# Softer vowels (the open probe).
render soft-um-comma "Um, one moment."
render soft-well "Well, one moment."
render soft-oh "Oh, one moment."
render soft-letmesee "Let me see. Checking the time in Tokyo."
render soft-midsentence "I'll check the time in Tokyo, um, one moment."
render soft-um-ell "Um..."
render soft-hmm-ell "Hmm..."
render soft-huh-low "huh."
# Safe words (what ships).
render yeah "Yeah."
render right "Right."
render i-see "I see."
render got-it "Got it."
render okay "Okay."

cp "$ROOT/docs/voice-audition.html" "$OUT/audition.html"
echo "audition page: $OUT/audition.html"
open "$OUT/audition.html" 2>/dev/null || true
