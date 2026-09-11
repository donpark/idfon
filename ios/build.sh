#!/bin/bash
# Build the UIKit app for a physical device (Release) into ios/.derived/.
# The app handles media (camera/mic/radio) — device is the default target.
# Pass --sim for a Debug simulator build instead.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"

"$ios_dir/build-deps.sh" ${1:-}

if [ "${1:-}" = "--sim" ]; then
  xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon \
    -destination 'generic/platform=iOS Simulator' ARCHS=arm64 \
    -derivedDataPath "$ios_dir/.derived" -configuration Debug build
  echo "app (sim):    $ios_dir/.derived/Build/Products/Debug-iphonesimulator/Idfon.app"
  exit 0
fi

xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon \
  -destination 'generic/platform=iOS' ARCHS=arm64 \
  -derivedDataPath "$ios_dir/.derived" -configuration Release -allowProvisioningUpdates build
echo "app (device): $ios_dir/.derived/Build/Products/Release-iphoneos/Idfon.app"