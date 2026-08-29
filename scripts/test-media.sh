#!/bin/sh
set -eu

# Standalone media tests use Swift concurrency. Native SDK app builds link the
# runtime themselves; this wrapper supplies it for direct cargo test runs.
developer_dir="$(xcode-select --print-path)"
swift_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx"
core_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx"
export DYLD_LIBRARY_PATH="$swift_dir:$core_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
exec cargo test -p nufon-media "$@"
