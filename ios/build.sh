#!/bin/bash
# Build the UIKit app for a physical device (Release) into ios/.derived/.
# The app handles media (camera/mic/radio); device is the only target — the
# simulator has no real camera/mic/radio and is not supported.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"

"$ios_dir/build-deps.sh"

# Phonon 31m TTS is compiled in by default (the voice-agent mouth);
# IDFON_TTS_PHONON=0 opts out (ptts is referenced either way and stripped
# when unused).
extra=()
conds=""
if [ "${IDFON_TTS_PHONON:-1}" = "1" ]; then conds="PHONON_TTS"; fi
# ASR bundle: the English ship by default; =1 selects the 3.5 latin/560ms tier.
if [ "${IDFON_ASR_MULTILINGUAL:-0}" != "0" ]; then conds="${conds:+$conds }NEMOTRON_MULTILINGUAL"; fi
if [ -n "$conds" ]; then
  extra=(SWIFT_ACTIVE_COMPILATION_CONDITIONS="\$(inherited) $conds")
else
  # The project sets PHONON_TTS by default; the opt-out must override it.
  extra=(SWIFT_ACTIVE_COMPILATION_CONDITIONS='')
fi

xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon \
  -destination 'generic/platform=iOS' ARCHS=arm64 \
  -derivedDataPath "$ios_dir/.derived" -configuration Release -allowProvisioningUpdates \
  ${extra[@]+"${extra[@]}"} build
echo "app (device): $ios_dir/.derived/Build/Products/Release-iphoneos/Idfon.app"
