#!/bin/bash
# Build the UIKit app for the iOS simulator (Debug) into ios/.derived/.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"

"$ios_dir/build-deps.sh"

xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 \
  -derivedDataPath "$ios_dir/.derived" -configuration Debug build
echo "app: $ios_dir/.derived/Build/Products/Debug-iphonesimulator/Idfon.app"
