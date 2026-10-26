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

./build-deps.sh

# Phonon 31m TTS is a build-time option (arm64-only core; picked at runtime
# with IDFON_TTS=phonon). IDFON_TTS_PHONON=1 selects the ptts package in
# Package.swift and compiles PhononTtsEngine in.
extra=()
# Phonon 31m TTS is compiled in by default (it is the voice-agent mouth,
# 2026-10-25 ruling); IDFON_TTS_PHONON=0 opts out (the mouth then falls back
# to the language default and the macOS floor stays at 14).
if [ "${IDFON_TTS_PHONON:-1}" = "1" ]; then extra=(-Xswiftc -DPHONON_TTS); fi
swift build -c release ${extra[@]+"${extra[@]}"}

APP=build/Idfon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
# App icon: squircle-masked PNGs in Assets/AppIcon.iconset -> .icns (mac/Info.plist CFBundleIconFile)
iconutil -c icns Assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/Idfon "$APP/Contents/MacOS/Idfon"
cp "$ROOT/target/release/idfond" "$APP/Contents/MacOS/idfond"
cp Vendor/libiroh_c_ffi.dylib "$APP/Contents/MacOS/"
cp Vendor/libidfon_director.dylib "$APP/Contents/MacOS/"
# mlx-swift's Metal shader bundle: the mlx turn tier loads default.metallib
# from the app's resources, and mlx-c aborts hard when it is missing (an
# uncatchable C++ error). Ship it whenever mlx-swift is in the product.
if [ -d ".build/release/mlx-swift_Cmlx.bundle" ]; then
  cp -R ".build/release/mlx-swift_Cmlx.bundle" "$APP/Contents/Resources/"
fi
cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc sign the dlopen'd director dylib too: a stale signature on a relinked
# dylib gets it SIGKILLed at load (see scripts/test-e2e.sh).
codesign --force -s - "$APP/Contents/MacOS/libidfon_director.dylib"
codesign --force -s - "$APP"

echo "built $APP — open it (or: $APP/Contents/MacOS/Idfon)"