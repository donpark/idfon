#!/bin/bash
# Build the iOS-simulator trial app (ios-trial branch).
# Prereqs:
#   rustup target add aarch64-apple-ios-sim
#   SDK patches applied (see ios-sdk-patches/ — copies of the two patched
#   files in @native-sdk/cli; node_modules is not a repo, re-copy after
#   reinstalling the CLI).
set -e
cd "$(dirname "$0")/../native"

SIM_SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk/usr/include
RUST_ARCHIVE=vendor/iroh-c-ffi/target/aarch64-apple-ios-sim/release/libiroh_c_ffi.a
APP_DIR=.native/ios/Idfon.app
DEV=${1:-"FC1A29D3-8D2F-4D0C-A090-390BAB95692F"}  # simulator UDID

# 1. Rust c-ffi (daemon + client) as a static lib. LTO must stay OFF:
#    fat LTO breaks block2 unwind-shim symbol resolution at link time.
cd vendor/iroh-c-ffi
SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path) CARGO_PROFILE_RELEASE_LTO=off \
  cargo build --release --target aarch64-apple-ios-sim
cd ../..

# 2. Embed static library (TS core + FFI host module + Rust archive).
zig build lib --prefix .native/embed/aarch64-ios-simulator \
  -Dtarget=aarch64-ios-simulator -Doptimize=Debug

# 3. Repack: Xcode ld rejects zig archives (members not 8-byte aligned).
#    Must extract members first — repacking from the archive drops the
#    native_sdk_app_* C-API members.
rm -rf /tmp/idfon-arx && mkdir /tmp/idfon-arx
cd /tmp/idfon-arx
xcrun ar x "$OLDPWD/.native/embed/aarch64-ios-simulator/lib/libIdfon.a"
chmod 644 *.o && rm -f __.SYMDEF*
xcrun libtool -static -o /tmp/libIdfon-ios.a *.o
cd "$OLDPWD"

# 4. Link the UIKit host. Debug core archives reference __ubsan_handle_*,
#    so the ubsan runtime dylib is bundled and resolved via @executable_path.
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator \
  -fobjc-arc -O2 .native/ios/host/uikit_host.m \
  /tmp/libIdfon-ios.a "$RUST_ARCHIVE" \
  "$APP_DIR/libclang_rt.ubsan_iossim_dynamic.dylib" \
  -rpath @executable_path \
  -framework UIKit -framework Metal -framework QuartzCore \
  -framework Foundation -framework CoreGraphics -framework AVFoundation \
  -framework ImageIO -framework Security -framework AudioToolbox \
  -framework CoreAudio -framework SystemConfiguration -framework Network \
  -o "$APP_DIR/Idfon"

codesign --force --sign - "$APP_DIR/libclang_rt.ubsan_iossim_dynamic.dylib"
codesign --force --sign - "$APP_DIR"

# 5. Install + launch (no --console-pty: it blocks for the app's lifetime).
xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1 || true
xcrun simctl install "$DEV" "$APP_DIR"
xcrun simctl launch "$DEV" dev.native-sdk.native
