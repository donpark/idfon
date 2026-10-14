#!/bin/sh
set -eu

# Voice-turn stage report (docs/benchmarks.md): turns `idfon-auto` marker logs
# into per-stage latency tables. Thin wrapper over the pure-TS bench vertical
# (agents/bench/lib/report.ts) — the same code the bench Eve agent runs.
#
#   scripts/voice-latency-report.sh LOG...        # captured log files
#   ... | scripts/voice-latency-report.sh         # stdin (devicectl --console)
#   scripts/voice-latency-report.sh --self-test   # fixture check
#
# Reads the per-turn marker VoiceAgentSession writes (iOS + mac apps):
#   idfon-auto: voice-agent: turn=3 asr_gap_ms=1240 listen_ms=2100 reply_ms=870
#               speak_ms=2600 total_ms=6810
#
#   asr_gap_ms  turn detection: recognizer's last update -> commit (the
#               VoicePromptSegmenter silence gap; ~1200-1500 on the fallback
#               path, ~0 when the recognizer commits a final)
#   listen_ms   listening window for the caller's utterance
#   reply_ms    send -> agent reply arrival (network + agent turn)
#   speak_ms    TTS + playback (includes speak()'s ~800 ms post-roll hold)
#   total_ms    whole turn

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

case "${1:-}" in
  --self-test) exec node "$root/agents/bench/lib/bench.ts" report --self-test ;;
  -h|--help|help) sed -n '2,22p' "$0"; exit 0 ;;
esac

exec node "$root/agents/bench/lib/bench.ts" report "$@"
