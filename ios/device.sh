#!/bin/bash
# Build Idfon for a real iPhone (Release), install and launch it via devicectl.
# Extra arguments are passed to the app as launch arguments
# (e.g. ios/device.sh -dial mac). DEVICE=<name-or-udid> picks a specific
# device; otherwise the first available one is used.
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
  | grep "available" | grep -m1 -oE '[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}' || true)
if [ -n "${DEVICE:-}" ]; then
  device="$DEVICE"
elif [ -z "$device" ]; then
  echo "no available iPhone found (connect one, or set DEVICE=<name-or-udid>)" >&2
  exit 1
fi

echo "== installing to $device"
xcrun devicectl device install app --device "$device" "$app"

echo "== launching"
xcrun devicectl device process launch --terminate-existing --device "$device" app.idfon "$@"
