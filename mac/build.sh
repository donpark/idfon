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

swift build -c release

APP=build/Idfon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Idfon "$APP/Contents/MacOS/Idfon"
cp "$ROOT/target/release/idfond" "$APP/Contents/MacOS/idfond"
cp Vendor/libiroh_c_ffi.dylib "$APP/Contents/MacOS/"
cp Vendor/libidfon_director.dylib "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc sign the dlopen'd director dylib too: a stale signature on a relinked
# dylib gets it SIGKILLed at load (see scripts/test-e2e.sh).
codesign --force -s - "$APP/Contents/MacOS/libidfon_director.dylib"
codesign --force -s - "$APP"

echo "built $APP — open it (or: $APP/Contents/MacOS/Idfon)"