#!/bin/bash
# On-device P6 smoke test: Apple-native TTS (AVSpeechSynthesizer) plus an
# on-device STT (SFSpeechRecognizer, requiresOnDeviceRecognition) round trip
# over the synthesized file. No microphone, no network.
#
#   scripts/ios-voice-provider-test.sh [--device <id-or-name>] [--no-build]
#
# First run prompts for Speech Recognition permission; tap Allow once.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"
device="${IPHONE_UDID:-${IPHONE_NAME:-${DEVICE:-}}}"
build=1
while [ $# -gt 0 ]; do
  case "$1" in
    --device) device="$2"; shift 2;;
    --no-build) build=0; shift;;
    *) echo "usage: $0 [--device UDID] [--no-build]" >&2; exit 2;;
  esac
done
if [ -z "$device" ]; then
  device=$(xcrun devicectl list devices 2>/dev/null \
    | grep -E "connected.*physical|physical.*connected" \
    | grep -m1 -oE '[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}' || true)
fi
[ -n "$device" ] || { echo "no connected physical iPhone; set IPHONE_UDID or --device" >&2; exit 2; }

if [ "$build" = 1 ]; then
  "$ios_dir/build-deps.sh"
  xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon \
    -destination 'generic/platform=iOS' ARCHS=arm64 \
    -derivedDataPath "$ios_dir/.derived" -configuration Release build >/dev/null
fi
app="$ios_dir/.derived/Build/Products/Release-iphoneos/Idfon.app"
[ -d "$app" ] || { echo "no built app at $app (run without --no-build)" >&2; exit 2; }

log=$(mktemp /tmp/idfon-ios-voice-provider.XXXXXX)
xcrun devicectl device install app --device "$device" "$app" >/dev/null
echo "launching on-device voice provider test; log=$log"
xcrun devicectl device process launch --device "$device" --terminate-existing \
  --console app.idfon -- -voicetest >"$log" 2>&1 &
launch_pid=$!

for _ in $(seq 1 120); do
  grep -q 'idfon-auto: voice: done' "$log" 2>/dev/null && break
  sleep 1
done
kill "$launch_pid" 2>/dev/null || true

if ! grep -q 'idfon-auto: voice: done' "$log" 2>/dev/null; then
  echo "FAIL: no result (first run needs the Speech Recognition permission tap?)" >&2
  cat "$log" >&2
  exit 1
fi
if ! grep -q 'idfon-auto: voice: PASS' "$log"; then
  echo "FAIL: on-device voice round trip" >&2
  cat "$log" >&2
  exit 1
fi
grep 'idfon-auto: voice:' "$log"
echo "PASS: Apple-native on-device TTS + on-device STT"
