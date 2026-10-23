#!/bin/bash
# Build the UIKit app for a physical device (Release) into ios/.derived/.
# The app handles media (camera/mic/radio); device is the only target — the
# simulator has no real camera/mic/radio and is not supported.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"

"$ios_dir/build-deps.sh"

# Phonon 31m TTS is a build-time option: IDFON_TTS_PHONON=1 compiles
# PhononTtsEngine in (ptts is referenced either way and stripped when unused).
extra=()
if [ "${IDFON_TTS_PHONON:-}" = "1" ]; then
  extra=(SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PHONON_TTS')
fi

xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon \
  -destination 'generic/platform=iOS' ARCHS=arm64 \
  -derivedDataPath "$ios_dir/.derived" -configuration Release -allowProvisioningUpdates \
  ${extra[@]+"${extra[@]}"} build
echo "app (device): $ios_dir/.derived/Build/Products/Release-iphoneos/Idfon.app"
