#!/usr/bin/env bash
# Vendor the Cactus Needle engine used by WhistleAsr:
#   ios:  ios/Vendor/device/libneedle.a  (gitignored; the iOS bridging header
#         includes ios/Idfon/needle.h)
#   mac:  mac/Vendor/libneedle.a         (committed, see below)
#
# The headers are committed (`ios/Idfon/needle.h`,
# `mac/Sources/CNeedle/include/needle.h`); this fetches the static libraries.
# Apache-2.0 (Cactus-Compute/needle3).
#
# Usage: scripts/fetch-needle.sh [ios-dest]   (default: ios/Vendor/device)
set -euo pipefail

dest="${1:-ios/Vendor/device}"
base="https://huggingface.co/Cactus-Compute/needle3/resolve/main"
mkdir -p "$dest"
echo "fetching ios-arm64/libneedle.a …"
curl -fsSL --retry 3 -o "$dest/libneedle.a" "$base/ios-arm64/libneedle.a"
echo "vendored $dest/libneedle.a ($(wc -c < "$dest/libneedle.a") bytes)"

echo "fetching macos-arm64/libneedle.a …"
curl -fsSL --retry 3 -o "mac/Vendor/libneedle.a" "$base/macos-arm64/libneedle.a"
echo "vendored mac/Vendor/libneedle.a ($(wc -c < mac/Vendor/libneedle.a) bytes)"
