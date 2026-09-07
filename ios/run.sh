#!/bin/bash
# Install + launch the Debug simulator app on the booted simulator.
# Extra arguments are passed to the app as launch arguments
# (e.g. ios/run.sh -dial mac, ios/run.sh -answer, ios/run.sh -memo 3 mac).
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"
app="$ios_dir/.derived/Build/Products/Debug-iphonesimulator/Idfon.app"

[ -d "$app" ] || { echo "app not built — run ios/build.sh first" >&2; exit 1; }

udid=$(xcrun simctl list devices booted | grep -m1 -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}')
[ -n "$udid" ] || { echo "no booted simulator" >&2; exit 1; }

xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
xcrun simctl terminate "$udid" app.idfon 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl launch "$udid" app.idfon "$@"
