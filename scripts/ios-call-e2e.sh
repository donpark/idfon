#!/bin/bash
# Paired-device E2E for the Swift/UIKit media path.
# Requires the Mac app running with a paired identity/peer and a connected iPhone.
# Usage: scripts/ios-call-e2e.sh --peer mac [--device UDID] [--no-build]
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"
device="${IPHONE_UDID:-${IPHONE_NAME:-${DEVICE:-}}}"
peer="mac"
build=1
while [ $# -gt 0 ]; do
  case "$1" in
    --peer) peer="$2"; shift 2;;
    --device) device="$2"; shift 2;;
    --no-build) build=0; shift;;
    *) echo "usage: $0 --peer REF [--device UDID] [--no-build]" >&2; exit 2;;
  esac
done
if [ -z "$device" ]; then
  device=$(xcrun devicectl list devices 2>/dev/null | grep -E "connected.*physical|physical.*connected" | grep -m1 -oE '[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}' || true)
fi
[ -n "$device" ] || { echo "no connected physical iPhone; set IPHONE_UDID, IPHONE_NAME, DEVICE, or --device" >&2; exit 2; }
if [ "$build" = 1 ]; then
  "$ios_dir/build-deps.sh"
  xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon -destination 'generic/platform=iOS' ARCHS=arm64 -derivedDataPath "$ios_dir/.derived" -configuration Release build >/dev/null
fi
app="$ios_dir/.derived/Build/Products/Release-iphoneos/Idfon.app"
log=$(mktemp /tmp/idfon-ios-call-e2e.XXXXXX)
launch() { xcrun devicectl device process launch --device "$device" --terminate-existing --console app.idfon -- "$@" >"$log" 2>&1; }
install() { xcrun devicectl device install app --device "$device" "$app" >/dev/null; }
check() { grep -qF "$1" "$log" || { echo "FAIL: missing '$1'"; cat "$log"; exit 1; }; echo "ok: $1"; }
install
launch -answer & answer_pid=$!
sleep 3
# The Mac side should be launched separately with -dial/-videodial. This script
# verifies the iOS receiver exercised the Swift call state machine.
echo "iOS answerer launched; start the Mac caller now. log=$log"
for _ in $(seq 1 180); do
  grep -q "idfon .*answer started" "$log" && break
  sleep 1
done
kill "$answer_pid" 2>/dev/null || true
check "idfon audio answer started"
echo "PASS: iOS Swift audio answer path; log=$log"
