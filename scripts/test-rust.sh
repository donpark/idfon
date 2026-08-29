#!/bin/sh
set -eu

developer_dir="$(xcode-select --print-path)"
swift_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx"
core_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx"
export DYLD_LIBRARY_PATH="$swift_dir:$core_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
exec cargo test --workspace "$@"
