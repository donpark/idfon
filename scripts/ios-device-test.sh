#!/bin/bash
# On-device automation for the flows that can't run headlessly (no simulator
# involved). Drives the *real* attachment path with no taps via the
# `-sendfile` launch argument (see ios/Idfon/Automation.swift) and asserts the
# Session Tray / file-transfer markers from the app's console.
#
#   scripts/ios-device-test.sh --peer <peer-ref> --file <path> \
#       [--device <id-or-name>] [--timeout 60] [--no-build]
#
#   --peer      peer ref/name/id to send to (or $PEER)
#   --file      local file to send; staged into the app's Documents directory
#   --device    device to use (or $DEVICE); default = first paired available iPhone
#   --timeout   seconds to wait for the transfer to finish (default 60)
#   --no-build  reuse the already-built/installed app (skips the Rust + app build)
#
# Needs a reachable peer (e.g. a mac running idfond) that this device is paired
# with. Compares nothing on the peer side — pair the peer and watch its console
# for `idfon file: received`.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"
bundle_id=app.idfon

peer="${PEER:-}"
file=""
device="${DEVICE:-}"
timeout_s=60
build=1

usage() { sed -n '2,20p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --peer) peer="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --device) device="$2"; shift 2 ;;
    --timeout) timeout_s="$2"; shift 2 ;;
    --no-build) build=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$peer" ] || { echo "need --peer <peer-ref>" >&2; exit 2; }
[ -n "$file" ] || { echo "need --file <path>" >&2; exit 2; }
[ -f "$file" ] || { echo "no such file: $file" >&2; exit 2; }

if [ -z "$device" ]; then
  device=$(xcrun devicectl list devices 2>/dev/null \
    | grep "available" | grep -m1 -oE '[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}' || true)
fi
[ -n "$device" ] || { echo "no paired iPhone found (set --device)" >&2; exit 2; }

if [ "$build" = 1 ]; then
  echo "== building device libs + app"
  "$ios_dir/build-deps.sh"
  xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon \
    -destination 'generic/platform=iOS' ARCHS=arm64 \
    -derivedDataPath "$ios_dir/.derived" -configuration Release build
fi

app="$ios_dir/.derived/Build/Products/Release-iphoneos/Idfon.app"
[ -d "$app" ] || { echo "app not built at $app (drop --no-build)" >&2; exit 2; }

name=$(basename "$file")
echo "== installing on $device"
xcrun devicectl device install app --device "$device" "$app" >/dev/null

echo "== staging $name in the app container's Documents/"
xcrun devicectl device copy to --device "$device" \
  --domain-type appDataContainer --domain-identifier "$bundle_id" \
  --source "$file" --destination "Documents/$name" >/dev/null

log=$(mktemp /tmp/idfon-device-test.XXXXXX)
echo "== launching -sendfile $peer $name (timeout ${timeout_s}s, log $log)"
xcrun devicectl device process launch --device "$device" --terminate-existing --console \
  "$bundle_id" -sendfile "$peer" "$name" >"$log" 2>&1 &
launcher=$!
trap 'kill "$launcher" 2>/dev/null || true' EXIT

# Stop as soon as the tray row finishes, or when the launcher dies / times out.
deadline=$(( $(date +%s) + timeout_s ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  kill -0 "$launcher" 2>/dev/null || break
  grep -q "idfon tray: finish" "$log" 2>/dev/null && break
  sleep 1
done
kill "$launcher" 2>/dev/null || true
wait "$launcher" 2>/dev/null || true

echo "== markers"
fail=0
for marker in \
  "idfon-auto: sendfile start" \
  "idfon tray: begin" \
  "idfon file: sent" \
  "idfon tray: finish"
do
  if grep -qF "$marker" "$log"; then
    echo "ok:   $marker"
  else
    echo "FAIL: missing '$marker'"
    fail=1
  fi
done

echo "== console (idfon lines)"
grep -E "idfon-auto:|idfon tray:|idfon file:" "$log" | tail -20 || true

if [ "$fail" != 0 ]; then
  echo "FAILED — full console: $log"
  exit 1
fi
echo "PASS — peer should log 'idfon file: received'"
