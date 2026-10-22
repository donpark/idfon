#!/bin/bash
# Build the Rust deps the mac app links/stages: the c-ffi dylib and idfond,
# then copy the dylib into mac/Vendor/ for the Swift link. Cargo is
# incremental, so re-running after a source change is cheap (this is what the
# old "only if the file is missing" check in build.sh got wrong).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

# Build objects for the app's link target (Package.swift: .macOS(.v14));
# otherwise cargo uses the SDK default and ld warns once per object.
export MACOSX_DEPLOYMENT_TARGET=14.0

echo "== libiroh_c_ffi.dylib"
(cd "$ROOT" && cargo build --release -p iroh-c-ffi)

echo "== idfond"
(cd "$ROOT" && cargo build --release -p idfond)

echo "== libidfon_director.dylib (on-device AFM voice-agent loop)"
(cd "$ROOT" && cargo build --release -p idfon-director --features afm --target aarch64-apple-darwin)

mkdir -p Vendor
cp "$ROOT/target/release/libiroh_c_ffi.dylib" Vendor/
# rustc bakes the build-machine deps/ path in as the dylib's install name, so
# a linked app would load THAT file and ignore the bundled copy (fine on this
# machine, a missing-dylib crash everywhere else). Rewrite the id and re-sign:
# a relinked dylib with a stale ad-hoc signature is SIGKILLed at load.
install_name_tool -id @executable_path/libiroh_c_ffi.dylib Vendor/libiroh_c_ffi.dylib
codesign --force -s - Vendor/libiroh_c_ffi.dylib

# The director's AFM shim needs macOS 26 (AFM3 paths gate at macOS 27 inside
# fm-rs), so it gets its own dylib with a matching min OS and only the C ABI
# exported. The app links at macOS 14 and dlopens this at first use
# (Sources/CIdfon/CIdfon.c); below macOS 26 the dlopen fails and the director
# is simply unavailable.
cat > Vendor/idfon_director.exports <<'EOF'
_idfon_director_new
_idfon_director_new_afm
_idfon_director_new_afm_config
_idfon_director_new_afm_wrapped
_idfon_director_prewarm
_idfon_director_turn
_idfon_director_turn_input
_idfon_director_free
_idfon_director_free_string
EOF
xcrun swiftc -emit-library \
    -target arm64-apple-macosx26.0 \
    -module-name idfon_director \
    -o Vendor/libidfon_director.dylib \
    -Xlinker -install_name -Xlinker @executable_path/libidfon_director.dylib \
    -Xlinker -exported_symbols_list -Xlinker Vendor/idfon_director.exports \
    "$ROOT/target/aarch64-apple-darwin/release/libidfon_director.a" \
    -framework FoundationModels -framework SystemConfiguration -lc++

echo "staged $PWD/Vendor/libiroh_c_ffi.dylib + libidfon_director.dylib (+ $ROOT/target/release/idfond)"