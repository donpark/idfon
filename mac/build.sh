#!/bin/bash
# Builds Idfon.app (macOS) from the Swift sources in this directory.
#
# Rust deps (libiroh_c_ffi.dylib + idfond) are built once by cargo and reused
# from the repo's release targets; the dylib is staged into Vendor/ for the
# Swift link, then shipped inside the .app next to the executable (its
# install name is @executable_path/libiroh_c_ffi.dylib).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

if [ ! -f "$ROOT/native/vendor/iroh-c-ffi/target/release/libiroh_c_ffi.dylib" ]; then
  echo "building libiroh_c_ffi.dylib (first run, several minutes)..."
  (cd "$ROOT/native/vendor/iroh-c-ffi" && RUSTFLAGS="-A unexpected_cfgs" cargo build --release)
fi
if [ ! -f "$ROOT/target/release/idfond" ]; then
  echo "building idfond..."
  (cd "$ROOT" && cargo build --release -p idfond)
fi
mkdir -p Vendor
cp "$ROOT/native/vendor/iroh-c-ffi/target/release/libiroh_c_ffi.dylib" Vendor/

swift build -c release

APP=build/Idfon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Idfon "$APP/Contents/MacOS/Idfon"
cp "$ROOT/target/release/idfond" "$APP/Contents/MacOS/idfond"
cp Vendor/libiroh_c_ffi.dylib "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Idfon</string>
    <key>CFBundleDisplayName</key><string>Idfon</string>
    <key>CFBundleIdentifier</key><string>app.idfon.mac</string>
    <key>CFBundleExecutable</key><string>Idfon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCameraUsageDescription</key><string>Idfon uses the camera for video calls.</string>
    <key>NSMicrophoneUsageDescription</key><string>Idfon uses the microphone for calls and voice messages.</string>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"

echo "built $APP — open it (or: $APP/Contents/MacOS/Idfon)"