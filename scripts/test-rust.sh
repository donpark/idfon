#!/bin/sh
set -eu

developer_dir="$(xcode-select --print-path)"
swift_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx"
core_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx"
export DYLD_LIBRARY_PATH="$swift_dir:$core_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

# Must match native/build.zig's cargo step exactly: same flags avoid a
# fingerprint flip-flop (full iroh rebuilds) and keep the dylib's install
# name @executable_path/... (an absolute install name breaks the thin
# nufond binary and the app bundle).
RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib"
export RUSTFLAGS

# The thin nufond binary links the vendored dylib (crates/nufond/build.rs),
# so it must exist before the workspace build.
cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml

# Workspace crates (protocol, daemon, CLI, media, client).
cargo test --workspace "$@"

# Vendored cdylib (excluded from the workspace): IPC client FFI.
cargo test --manifest-path native/vendor/iroh-c-ffi/Cargo.toml --lib "$@"
