#!/bin/bash
# Build Idfon for a real iPhone (Release), install and launch it via devicectl.
# Extra arguments are passed to the app as launch arguments
# (e.g. ios/device.sh -dial mac). IPHONE_UDID or IPHONE_NAME picks a
# specific device; DEVICE remains a compatibility alias.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"

"$ios_dir/build-deps.sh"

CONFIG=${CONFIG:-Release}
xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon \
  -destination 'generic/platform=iOS' ARCHS=arm64 \
  -derivedDataPath "$ios_dir/.derived" -configuration "$CONFIG" build

app="$ios_dir/.derived/Build/Products/${CONFIG}-iphoneos/Idfon.app"

# Prove what is about to ship: the binary must carry the current build
# stamp ("idfon build stamp …" in AppDelegate). Testing a stale install
# while believing it is new has cost whole E2E rounds.
stamp=$(strings "$app/Idfon" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}\.[a-z0-9]+' | head -1)
echo "device.sh: build stamp = ${stamp:-MISSING} (expect AppDelegate.buildStamp)"

# If several devices are attached, guessing which phone is the user's wife
# costs a whole run (it silently installed to the wrong phone once).
# Never guess: require an explicit pick when more than one is connected.
candidates=$(xcrun devicectl list devices 2>/dev/null \
  | grep -E "connected.*physical|physical.*connected" \
  | grep -oE '[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}' | sort -u || true)
if [ -n "${IPHONE_UDID:-}" ]; then
  device="$IPHONE_UDID"
elif [ -n "${IPHONE_NAME:-}" ]; then
  device="$IPHONE_NAME"
elif [ -n "${DEVICE:-}" ]; then
  device="$DEVICE"
elif [ "$(printf '%s\n' "$candidates" | grep -c .)" -gt 1 ]; then
  echo "multiple connected iPhones; pick one explicitly:" >&2
  xcrun devicectl list devices >&2
  echo "usage: IPHONE_UDID=<udid> $0   (or IPHONE_NAME=<name>)" >&2
  exit 1
else
  device="$candidates"
  if [ -z "$device" ]; then
    echo "no connected iPhone found (set IPHONE_UDID, IPHONE_NAME, or DEVICE)" >&2
    exit 1
  fi
fi

echo "== installing to $device"
# CoreDevice can transiently invalidate its control channel while the phone
# remains paired/available. Retry one time after rediscovering the device;
# do not rebuild or silently select another device.
if ! xcrun devicectl device install app --device "$device" "$app"; then
  echo "device install failed; refreshing CoreDevice connection and retrying once" >&2
  sleep 2
  xcrun devicectl list devices >/dev/null
  xcrun devicectl device install app --device "$device" "$app"
fi

echo "== launching"
# `--` stops devicectl from parsing the app's own -flags (e.g. -dial) as its
# own options; without it every launch argument fails with "Unknown option".
xcrun devicectl device process launch --terminate-existing --device "$device" com.idfon.ios -- "$@"
