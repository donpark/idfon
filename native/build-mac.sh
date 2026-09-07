#!/bin/bash
# Build Idfon.app. Force ad-hoc re-sign of everything copied into the bundle:
# relinked Mach-O files keep stale ad-hoc signatures that macOS kills at exec
# (SIGKILL Code Signature Invalid), even though `codesign -v` passes.
set -euo pipefail
cd "$(dirname "$0")"

native build
native package --target macos --binary 'zig-out/bin/Idfon' --output 'Idfon.app'
cp ../target/release/idfond 'Idfon.app/Contents/MacOS/idfond'
cp zig-out/bin/libiroh_c_ffi.dylib 'Idfon.app/Contents/MacOS/'
codesign --force -s - \
  'Idfon.app/Contents/MacOS/libiroh_c_ffi.dylib' \
  'Idfon.app/Contents/MacOS/idfond' \
  'Idfon.app/Contents/MacOS/Idfon'
codesign --force -s - 'Idfon.app'
