#!/usr/bin/env bash
# Render the Opus loss-harness speech fixture with Phonon (ptts).
# Never macOS `say` — use the project's own engines.
#
#   scripts/opus-loss-fixture.sh [OUT.wav]
#
# PTTS overrides the ptts binary (default: ptts on PATH; build an xn-ptts
# checkout with `cargo build --release --bin ptts --features cli`).
# Output: PCM16 mono 24 kHz, the voice-agent call leg's format, consumed by
# `cargo test -p idfon-media --test opus_redundancy` (docs/media-adaptation.md §D7).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/target/opus-loss-fixture.wav}"
PTTS="${PTTS:-ptts}"
command -v "$PTTS" >/dev/null 2>&1 || {
  echo "opus-loss-fixture: ptts not found. Build xn-ptts with --features cli and pass its path via PTTS." >&2
  exit 2
}
mkdir -p "$(dirname "$OUT")"
"$PTTS" --lang en "So, one moment. Let me check the time in Tokyo for you. Hmm, it is just after nine in the evening there. Yeah, tomorrow works for me. I will send the details over once I am back at my desk. Okay, talk soon." -o "$OUT"
echo "$OUT"
