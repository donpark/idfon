#!/bin/sh
# Build the idfon Eve channel endpoint holder and populate the matching npm
# platform package (bin/idfon-eve-channel) for the idfon-eve-channel package.
#
# Usage:
#   scripts/build-eve-channel.sh          # host target (what CI runs: one runner per target)
#   scripts/build-eve-channel.sh TARGET   # cross build (same targets/toolchain notes as build-cli.sh):
#                                           x86_64-/aarch64-apple-darwin   native macOS SDK cross
#                                           x86_64-/aarch64-unknown-linux-gnu  cargo zigbuild; needs a
#                                           native Linux machine or sysroot for the ALSA headers
#
# The holder is a self-contained Rust binary (no vendored iroh dylib), so no
# rpath/install_name flags are needed; only the macOS ad-hoc signature is
# refreshed after relinking.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

host=$(rustc -vV | sed -n 's/^host: //p')
target=${1:-$host}
if [ "$target" != "$host" ]; then
  rustup target add "$target"
fi

case "$target" in
  aarch64-apple-darwin) pkg=idfon-eve-channel-darwin-arm64 ;;
  x86_64-apple-darwin) pkg=idfon-eve-channel-darwin-x64 ;;
  x86_64-unknown-linux-gnu) pkg=idfon-eve-channel-linux-x64 ;;
  aarch64-unknown-linux-gnu) pkg=idfon-eve-channel-linux-arm64 ;;
  *)
    echo "build-eve-channel.sh: unsupported target: $target" >&2
    exit 1
    ;;
esac

cross_flag=""
build="cargo build"
if [ "$target" != "$host" ]; then
  cross_flag="--target $target"
  case "$target" in
    *linux-gnu)
      command -v cargo-zigbuild >/dev/null 2>&1 || {
        echo "build-eve-channel.sh: linux cross needs cargo-zigbuild (brew install zig cargo-zigbuild)" >&2
        exit 1
      }
      build="cargo zigbuild"
      ;;
  esac
fi

$build --release -p idfon-eve-channel $cross_flag

if [ -n "$cross_flag" ]; then out="target/$target/release"; else out="target/release"; fi
case "$target" in
  *apple-darwin)
    # A relink can leave an ad-hoc signature that no longer matches the pages;
    # the kernel then SIGKILLs the process at exec ("Code Signature Invalid").
    codesign --force -s - "$out/idfon-eve-channel"
    ;;
esac

pkgdir="$root/integrations/$pkg"
mkdir -p "$pkgdir/bin"
cp "$out/idfon-eve-channel" "$pkgdir/bin/"
cp "$root/LICENSE-APACHE" "$root/LICENSE-MIT" "$pkgdir/"
echo "build-eve-channel.sh: populated $pkgdir/bin ($target)"