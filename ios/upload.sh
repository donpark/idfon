#!/bin/bash
# Archive, export, gate and upload an iOS build to App Store Connect (TestFlight).
# Sibling of build.sh (docs/testflight-plan.md).
#
# Usage: ios/upload.sh          export + gates + upload (as below)
#        ios/upload.sh archive  stop after export + gates (no upload) at
#                               build/export/Idfon.ipa
#   APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD set -> also uploads via altool;
#   otherwise the run stops at build/export/Idfon.ipa (upload it from
#   Transporter). Every run bumps CURRENT_PROJECT_VERSION
#   (CFBundleVersion) in the pbxproj — TestFlight rejects reused build numbers.
#   Commit the bump with whatever is shipping.
#
# This script never stages a raw .xcarchive and never feeds Xcode's Organizer:
# a raw archive is development-entitled (step 2) and an Organizer-based upload
# shipped exactly that once (2026-11-09: sandbox VoIP tokens, nothing rings).
# The only artifact that leaves here is the gated, production-entitled IPA.
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

# The app's embedded aps-environment entitlement (empty if absent/unreadable).
aps_environment_of() {
  codesign -d --entitlements - --xml "$1" 2>/dev/null \
    | plutil -extract aps-environment raw -o - - 2>/dev/null
}

# 1. Unique build number per upload.
n=$(grep -m1 'CURRENT_PROJECT_VERSION = ' Idfon.xcodeproj/project.pbxproj | grep -oE '[0-9]+')
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $((n + 1));/" \
  Idfon.xcodeproj/project.pbxproj
echo "upload.sh: CFBundleVersion $n -> $((n + 1))"

# 2. Archive. The archive is ALWAYS development-entitled: automatic signing
#    signs it with the dev team profile and the embedded entitlements come
#    from that profile, not from Idfon.entitlements (verified 2026-11-09 —
#    overriding the file or pinning the store profile cannot change this).
#    Only the export in step 3 re-signs to production. A raw .xcarchive must
#    therefore never be distributed: Xcode Organizer's "Distribute App" has
#    shipped the archive's development aps-environment — sandbox VoIP tokens
#    that never register anywhere and nothing rings (the 2026-11-09 wake
#    saga). This script refuses to feed that path: its only output is the
#    gated IPA below.
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

# 4. Gate the artifact that actually ships (extracted from the IPA).
tmp=$(mktemp -d)
unzip -q "$ipa" -d "$tmp"
app="$tmp/Payload/Idfon.app"
# a) aps-environment must be production (App Store Connect rejects
#    'development' with 90046; verified 2026-10-24). A TestFlight build whose
#    entitlement (development) disagrees with its profile (production) mints
#    sandbox tokens that never register anywhere — the locked-phone wake saga.
#    This gate is the shipping invariant: no development-entitled artifact
#    ever leaves this script.
if [ "$(aps_environment_of "$app")" != production ]; then
  echo "upload.sh: aps-environment is not production — distribution signing missing" >&2
  exit 1
fi
# The embedded profile must authorize the same value, and the build must not
# be debuggable (Apple QA1798: check the signature entitlements AND the
# profile — their disagreement is exactly the "sandbox tokens, nothing rings"
# class).
prof_aps=$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null \
  | plutil -extract Entitlements.aps-environment raw -o - - 2>/dev/null)
if [ "$prof_aps" != production ]; then
  echo "upload.sh: embedded profile aps-environment is '$prof_aps', not production" >&2
  exit 1
fi
if [ "$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -extract get-task-allow raw -o - - 2>/dev/null)" = true ]; then
  echo "upload.sh: get-task-allow is set — development-signed artifact" >&2
  exit 1
fi
# b) ship hygiene (rig residue / bundled key) — see check_ship_hygiene.
check_ship_hygiene "$app"
rm -rf "$tmp"
echo "upload.sh: gates ok (aps-environment=production in entitlements and profile, not debuggable, no rig residue)"

# 5. Upload. (Archive mode: stop here with the gated IPA. Historically this
#    mode staged a .xcarchive for Xcode's Organizer — that path shipped broken
#    builds and is gone; upload build/export/Idfon.ipa from Transporter.)
if [ "$mode" = archive ]; then
  echo "upload.sh: exported $ipa — upload it from Transporter (or run without 'archive' to altool)"
  exit 0
fi
if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
  xcrun altool --upload-app -f "$ipa" -t ios \
    -u "$APPLE_ID" -p "$APPLE_APP_SPECIFIC_PASSWORD"
else
  echo "upload.sh: exported $ipa — set APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD to upload"
fi
