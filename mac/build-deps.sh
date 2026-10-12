#!/bin/bash
# Build the Rust deps the mac app links/stages: the c-ffi dylib and idfond,
# then copy the dylib into mac/Vendor/ for the Swift link. Cargo is
# incremental, so re-running after a source change is cheap (this is what the
# old "only if the file is missing" check in build.sh got wrong).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

echo "== libiroh_c_ffi.dylib"
(cd "$ROOT/native/vendor/iroh-c-ffi" && RUSTFLAGS="-A unexpected_cfgs" cargo build --release)

echo "== idfond"
(cd "$ROOT" && cargo build --release -p idfond)

echo "== libidfon_director.a (on-device AFM voice-agent loop)"
(cd "$ROOT" && cargo build --release -p idfon-director --features afm --target aarch64-apple-darwin)

mkdir -p Vendor
cp "$ROOT/native/vendor/iroh-c-ffi/target/release/libiroh_c_ffi.dylib" Vendor/
cp "$ROOT/target/aarch64-apple-darwin/release/libidfon_director.a" Vendor/

echo "staged $PWD/Vendor/libiroh_c_ffi.dylib + libidfon_director.a (+ $ROOT/target/release/idfond)"