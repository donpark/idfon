#!/bin/bash
# Build the Rust c-ffi staticlib for the DEVICE (aarch64-apple-ios) and stage
# into ios/Vendor/device/. Device only — the simulator has no real
# camera/mic/radio and is not supported.
# LTO off: fat LTO breaks block2 unwind-shim symbol resolution at link time.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ios_dir="$root/ios"

mkdir -p "$ios_dir/Vendor/device"
cd "$root/native/vendor/iroh-c-ffi"

echo "== aarch64-apple-ios"
# Deployment target >= 12: openh264's ___chkstk_darwin needs it, and the
# default (10.0) makes the final lib un-linkable.
SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path) IPHONEOS_DEPLOYMENT_TARGET=17.0 \
RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-miphoneos-version-min=17.0" CARGO_PROFILE_RELEASE_LTO=off \
  cargo build --release --target aarch64-apple-ios
cp target/aarch64-apple-ios/release/libiroh_c_ffi.a "$ios_dir/Vendor/device/"

echo "staged $ios_dir/Vendor/device/libiroh_c_ffi.a"

# The voice-agent harness (docs/build.md). `--features afm` links Apple
# Foundation Models via fm-rs; it is Apple-only. The app links the staticlib.
echo "== idfon-director (afm) aarch64-apple-ios"
cd "$root"
SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path) IPHONEOS_DEPLOYMENT_TARGET=17.0 \
RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-miphoneos-version-min=17.0" CARGO_PROFILE_RELEASE_LTO=off \
  cargo build --release -p idfon-director --features afm --target aarch64-apple-ios
cp target/aarch64-apple-ios/release/libidfon_director.a "$ios_dir/Vendor/device/"

# The fm-rs Swift layer (FoundationModels bindings) is compiled with min
# iOS 26 and rides inside this archive, so ld warns per object when the app
# links at 17.0. The app weak-links FoundationModels and only runs the agent
# on iOS 26+, so rewrite those members' LC_BUILD_VERSION minos to the link
# target — load-command metadata only, bytes otherwise untouched.
staged="$ios_dir/Vendor/device/libidfon_director.a"
tmp=$(mktemp -d)
( cd "$tmp" && ar x "$staged" )
python3 - "$tmp" <<'PY'
import glob, os, struct, sys
patched = 0
for path in glob.glob(os.path.join(sys.argv[1], "*.o")):
    data = bytearray(open(path, "rb").read())
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xfeedfacf:
        continue  # not a 64-bit Mach-O object
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, changed = 32, False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x32 and cmdsize >= 16:  # LC_BUILD_VERSION
            minos = struct.unpack_from("<I", data, off + 12)[0]
            if minos >> 16 >= 26:
                struct.pack_into("<I", data, off + 12, 17 << 16)  # 17.0
                changed = True
        off += cmdsize
    if changed:
        open(path, "wb").write(data)
        patched += 1
print(f"minos-patched {patched} fm-rs objects to iOS 17.0")
PY
( cd "$tmp" && ar r "$staged" ./*.o >/dev/null )
ranlib "$staged"
rm -rf "$tmp"

echo "staged $ios_dir/Vendor/device/libidfon_director.a"
