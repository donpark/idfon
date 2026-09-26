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

mkdir -p Vendor
cp "$ROOT/native/vendor/iroh-c-ffi/target/release/libiroh_c_ffi.dylib" Vendor/

echo "staged $PWD/Vendor/libiroh_c_ffi.dylib (+ $ROOT/target/release/idfond)"