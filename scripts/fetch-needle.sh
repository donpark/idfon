#!/usr/bin/env bash
# Vendor the Cactus Needle iOS engine used by WhistleAsr
# (`ios/Vendor/device/libneedle.a`). `ios/Vendor/` is gitignored, so run this
# once after checkout and on any engine version bump.
#
# The header (`ios/Idfon/needle.h`) is committed; only the static library is
# fetched. Apache-2.0 (Cactus-Compute/needle3).
#
# Usage: scripts/fetch-needle.sh [dest-dir]   (default: ios/Vendor/device)
set -euo pipefail

dest="${1:-ios/Vendor/device}"
base="https://huggingface.co/Cactus-Compute/needle3/resolve/main/ios-arm64"
mkdir -p "$dest"
echo "fetching $base/libneedle.a …"
curl -fsSL --retry 3 -o "$dest/libneedle.a" "$base/libneedle.a"
echo "vendored $dest/libneedle.a ($(wc -c < "$dest/libneedle.a") bytes)"
