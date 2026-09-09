#!/bin/bash
# Build the Rust c-ffi staticlib for iOS (simulator + device) and stage into
# ios/Vendor/. Flags mirror scripts/build-ios-sim.sh step 1 (LTO off: fat LTO
# breaks block2 unwind-shim symbol resolution at link time).
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"

mkdir -p "$ios_dir/Vendor/sim" "$ios_dir/Vendor/device"
cd "$root/native/vendor/iroh-c-ffi"

echo "== aarch64-apple-ios-sim"
SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path) IPHONEOS_DEPLOYMENT_TARGET=16.0 CARGO_PROFILE_RELEASE_LTO=off \
  cargo build --release --target aarch64-apple-ios-sim
cp target/aarch64-apple-ios-sim/release/libiroh_c_ffi.a "$ios_dir/Vendor/sim/"

echo "== aarch64-apple-ios"
# Deployment target >= 12: openh264's ___chkstk_darwin needs it, and the
# default (10.0) makes the final lib un-linkable.
SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path) IPHONEOS_DEPLOYMENT_TARGET=16.0 CARGO_PROFILE_RELEASE_LTO=off \
  cargo build --release --target aarch64-apple-ios
cp target/aarch64-apple-ios/release/libiroh_c_ffi.a "$ios_dir/Vendor/device/"

echo "staged $ios_dir/Vendor/{sim,device}/libiroh_c_ffi.a"
