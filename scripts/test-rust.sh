#!/bin/sh
set -eu

developer_dir="$(xcode-select --print-path)"
swift_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx"
core_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx"
export DYLD_LIBRARY_PATH="$swift_dir:$core_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

# The thin idfond binary links the C-FFI dylib (crates/idfond/build.rs),
# so it must exist before the workspace build.
cargo build --release -p iroh-c-ffi

# Workspace crates (protocol, daemon, CLI, media, client).
cargo test --workspace "$@"

# The C-FFI cdylib's own lib tests: IPC client FFI.
cargo test -p iroh-c-ffi --lib "$@"
