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

device=$(xcrun devicectl list devices 2>/dev/null \
  | grep -E "connected.*physical|physical.*connected" \
  | grep -m1 -oE '[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}' || true)
if [ -n "${IPHONE_UDID:-}" ]; then
  device="$IPHONE_UDID"
  elif [ -n "${IPHONE_NAME:-}" ]; then
  device="$IPHONE_NAME"
elif [ -n "${DEVICE:-}" ]; then
  device="$DEVICE"
elif [ -z "$device" ]; then
  echo "no connected iPhone found (set IPHONE_UDID, IPHONE_NAME, or DEVICE)" >&2
  exit 1
fi

echo "== installing to $device"
xcrun devicectl device install app --device "$device" "$app"

echo "== launching"
# `--` stops devicectl from parsing the app's own -flags (e.g. -dial) as its
# own options; without it every launch argument fails with "Unknown option".
xcrun devicectl device process launch --terminate-existing --device "$device" app.idfon -- "$@"
