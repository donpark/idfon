#!/bin/bash
# On-device P6 smoke test: Apple-native TTS (AVSpeechSynthesizer) plus an
# on-device STT (SFSpeechRecognizer, requiresOnDeviceRecognition) round trip
# over the synthesized file. No network. --listen transcribes live microphone
# speech instead (you speak after launch); --ffi drives the same engine through
# the Rust idfon-voice seam over the C ABI.
#
#   scripts/ios-voice-provider-test.sh [--device <id>] [--no-build] [--listen|--ffi|--bargein]
#
# First run prompts for Speech Recognition (and Microphone with --listen)
# permission; tap Allow once.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"
device="${IPHONE_UDID:-${IPHONE_NAME:-${DEVICE:-}}}"
build=1
mode_args=(-voicetest)
mode_label="TTS + on-device STT round trip"
wait_s=120
while [ $# -gt 0 ]; do
  case "$1" in
    --device) device="$2"; shift 2;;
    --no-build) build=0; shift;;
    --listen) mode_args=(-voicelisten); mode_label="live mic -> on-device STT"; wait_s=75; shift;;
    --ffi) mode_args=(-voiceffi); mode_label="Rust seam -> Swift engine (TTS+STT)"; wait_s=45; shift;;
    --bargein) mode_args=(-bargein); mode_label="barge-in over AEC playback"; wait_s=60; shift;;
    *) echo "usage: $0 [--device UDID] [--no-build] [--listen|--ffi|--bargein]" >&2; exit 2;;
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
if [ "${mode_args[0]}" = "-voicelisten" ]; then
  echo "launching $mode_label on device; speak clearly after it starts. log=$log"
elif [ "${mode_args[0]}" = "-bargein" ]; then
  echo "launching $mode_label on device; talk over the agent's speech to interrupt. log=$log"
else
  echo "launching $mode_label on device; log=$log"
fi
xcrun devicectl device process launch --device "$device" --terminate-existing \
  --console app.idfon -- "${mode_args[@]}" >"$log" 2>&1 &
launch_pid=$!

for _ in $(seq 1 "$wait_s"); do
  grep -q 'idfon-auto: voice: done' "$log" 2>/dev/null && break
  sleep 1
done
kill "$launch_pid" 2>/dev/null || true

if ! grep -q 'idfon-auto: voice: done' "$log" 2>/dev/null; then
  echo "FAIL: no result (first run needs the permission tap?)" >&2
  cat "$log" >&2
  exit 1
fi
if ! grep -q 'idfon-auto: voice: PASS' "$log"; then
  echo "FAIL: $mode_label" >&2
  cat "$log" >&2
  exit 1
fi
grep 'idfon-auto: voice:' "$log"
echo "PASS: Apple-native $mode_label"
