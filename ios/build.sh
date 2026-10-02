#!/bin/bash
# Build the UIKit app for a physical device (Release) into ios/.derived/.
# The app handles media (camera/mic/radio); device is the only target — the
# simulator has no real camera/mic/radio and is not supported.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"

"$ios_dir/build-deps.sh"

xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon \
  -destination 'generic/platform=iOS' ARCHS=arm64 \
  -derivedDataPath "$ios_dir/.derived" -configuration Release -allowProvisioningUpdates build
echo "app (device): $ios_dir/.derived/Build/Products/Release-iphoneos/Idfon.app"
