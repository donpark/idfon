#!/bin/bash
# Build the Rust c-ffi staticlib for the iOS simulator and stage it into
# ios/Vendor/. Flags mirror scripts/build-ios-sim.sh step 1 (LTO off: fat LTO
# breaks block2 unwind-shim symbol resolution at link time).
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"

mkdir -p "$ios_dir/Vendor"
cd "$root/native/vendor/iroh-c-ffi"
SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path) CARGO_PROFILE_RELEASE_LTO=off \
  cargo build --release --target aarch64-apple-ios-sim
cp target/aarch64-apple-ios-sim/release/libiroh_c_ffi.a "$ios_dir/Vendor/"
echo "staged $ios_dir/Vendor/libiroh_c_ffi.a"
