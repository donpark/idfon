#!/bin/bash
# Archive, export, gate and upload an iOS build to App Store Connect (TestFlight).
# Sibling of build.sh (docs/testflight-plan.md).
#
# Usage: ios/upload.sh          export + gates + upload (as below)
#        ios/upload.sh archive  stop after archiving and stage the .xcarchive
#                               into ~/Library/Developer/Xcode/Archives, ready
#                               to upload from Xcode's Organizer
#   APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD set -> also uploads via altool;
#   otherwise the run stops at build/export/Idfon.ipa (upload it from
#   Transporter or Xcode organizer). Every run bumps CURRENT_PROJECT_VERSION
#   (CFBundleVersion) in the pbxproj — TestFlight rejects reused build numbers.
#   Commit the bump with whatever is shipping.
#
# The first submission goes through Xcode by hand (Archive organizer ->
# Distribute App); this script exists for the convenience of the ones after.
set -euo pipefail
cd "$(dirname "$0")"
mode=${1:-}

# Ship-hygiene gates (shared by both paths): the rig's markers must never
# reach a shipping binary, and no APNs key may ride along.
check_ship_hygiene() {
  local app="$1"
  if strings "$app/Idfon" | grep -E -q 'e2etoken|sandbox\.push\.apple\.com|:8090|192\.168\.'; then
    echo "upload.sh: test-rig residue in the binary" >&2
    exit 1
  fi
  if find "$app" -name '*.p8' | grep -q .; then
    echo "upload.sh: APNs .p8 key bundled inside the app" >&2
    exit 1
  fi
}

# 1. Unique build number per upload.
n=$(grep -m1 'CURRENT_PROJECT_VERSION = ' Idfon.xcodeproj/project.pbxproj | grep -oE '[0-9]+')
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $((n + 1));/" \
  Idfon.xcodeproj/project.pbxproj
echo "upload.sh: CFBundleVersion $n -> $((n + 1))"

# 2. Archive. Automatic signing signs the archive with the *development* team
#    profile (aps-environment=development); the distribution profile is
#    applied at export below, which is where aps-environment flips.
./build-deps.sh
archive=build/Idfon.xcarchive
rm -rf "$archive"
xcodebuild archive -project Idfon.xcodeproj -scheme Idfon \
  -destination 'generic/platform=iOS' ARCHS=arm64 \
  -archivePath "$archive" -configuration Release -allowProvisioningUpdates

# Archive-only path: stage into Organizer's Archives directory (it only lists
# ~/Library/Developer/Xcode/Archives) and stop. Organizer's "Distribute App ->
# App Store Connect" applies the distribution profile — where
# aps-environment flips to production (the export path's gate below).
if [ "$mode" = archive ]; then
  check_ship_hygiene "$archive/Products/Applications/Idfon.app"
  stamp=$(date '+%Y-%m-%d %H.%M.%S')
  dest="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/Idfon $stamp.xcarchive"
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  cp -R "$archive" "$dest"
  echo "upload.sh: gates ok (no rig residue, no bundled key)"
  echo "upload.sh: staged for Organizer: $dest"
  echo "  Xcode → Window → Devices and More → Archives → Distribute App → App Store Connect"
  exit 0
fi

# 3. Export for App Store Connect (re-signs with the distribution profile).
cat > build/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>RV27HPQNMF</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST
rm -rf build/export
xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates
ipa=build/export/Idfon.ipa

# 4. Gate the artifact that actually ships (extracted from the IPA).
tmp=$(mktemp -d)
unzip -q "$ipa" -d "$tmp"
app="$tmp/Payload/Idfon.app"
# a) aps-environment must be production (App Store Connect rejects
#    'development' with 90046; verified 2026-10-24). The CLI export swaps the
#    entitlements file's development value to production from the
#    distribution profile — that swap is correct and must not be undone:
#    a TestFlight build whose entitlement (development) disagrees with its
#    profile (production) mints sandbox tokens that never register anywhere
#    — the locked-phone wake saga. The Xcode Organizer export keeps the file
#    value verbatim, so always upload THIS CLI-exported IPA.
codesign -d --entitlements "$tmp/ents" "$app" >/dev/null 2>&1
if ! grep -A2 'aps-environment' "$tmp/ents" | grep -q 'production'; then
  echo "upload.sh: aps-environment is not production — distribution signing missing" >&2
  exit 1
fi
# b) ship hygiene (rig residue / bundled key) — see check_ship_hygiene.
check_ship_hygiene "$app"
rm -rf "$tmp"
echo "upload.sh: gates ok (aps-environment=production, no rig residue)"

# 5. Upload.
if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
  xcrun altool --upload-app -f "$ipa" -t ios \
    -u "$APPLE_ID" -p "$APPLE_APP_SPECIFIC_PASSWORD"
else
  echo "upload.sh: exported $ipa — set APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD to upload"
fi
