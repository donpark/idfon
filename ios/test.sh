#!/bin/bash
# Run the app-hosted unit tests (ios/IdfonTests) on a connected iPhone.
# The app is device-only, so tests run on hardware; pass a device UDID as $1
# or set IDFON_DEVICE. With none given, the first paired, booted iPhone wins.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"

device="${1:-${IDFON_DEVICE:-}}"
if [ -z "$device" ]; then
  # A booted, paired device that is not a same-machine simulator.
  device=$(xcrun devicectl list devices --json-output - 2>/dev/null | jq -r '
    .result.devices[]
    | select(.connectionProperties.pairingState == "paired")
    | select(.deviceProperties.bootState == "booted")
    | select(.connectionProperties.transportType != "sameMachine")
    | .hardwareProperties.udid' | head -1)
fi
if [ -z "$device" ]; then
  echo "no connected iPhone found; pass a UDID or set IDFON_DEVICE" >&2
  exit 1
fi
echo "testing on device $device"

exec xcodebuild -project "$ios_dir/Idfon.xcodeproj" -scheme Idfon \
  -destination "platform=iOS,id=$device" \
  -derivedDataPath "$ios_dir/.derived" -configuration Debug -allowProvisioningUpdates test
