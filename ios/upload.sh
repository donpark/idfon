#!/bin/bash
# Archive, export, gate and upload an iOS build to App Store Connect (TestFlight).
# Sibling of build.sh (docs/testflight-plan.md).
#
# Usage: ios/upload.sh
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

# 4. Gates on the artifact that actually ships (extracted from the IPA).
tmp=$(mktemp -d)
unzip -q "$ipa" -d "$tmp"
app="$tmp/Payload/Idfon.app"
# a) aps-environment must be production (codesign dumps a [Key]/[Value] text
#    file). TestFlight builds carrying the development value ring through
#    sandbox APNs and calls silently die (edge-deploy-checklist.md §C).
codesign -d --entitlements "$tmp/ents" "$app" >/dev/null 2>&1
if ! grep -A2 'aps-environment' "$tmp/ents" | grep -q 'production'; then
  echo "upload.sh: aps-environment is not production — distribution signing missing" >&2
  exit 1
fi
# b) no test-rig residue (edge-deploy-checklist.md "rules"): the rig's markers
#    must never reach a shipping binary, and no APNs key may ride along.
if strings "$app/Idfon" | grep -E -q 'e2etoken|sandbox\.push\.apple\.com|:8090|192\.168\.'; then
  echo "upload.sh: test-rig residue in the binary" >&2
  exit 1
fi
if find "$app" -name '*.p8' | grep -q .; then
  echo "upload.sh: APNs .p8 key bundled inside the app" >&2
  exit 1
fi
rm -rf "$tmp"
echo "upload.sh: gates ok (aps-environment=production, no rig residue)"

# 5. Upload.
if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
  xcrun altool --upload-app -f "$ipa" -t ios \
    -u "$APPLE_ID" -p "$APPLE_APP_SPECIFIC_PASSWORD"
else
  echo "upload.sh: exported $ipa — set APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD to upload"
fi
