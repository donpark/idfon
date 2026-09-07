#!/bin/sh
# Build the idfon CLI + daemon + vendored iroh dylib and populate the matching
# platform package (bin/: idfon, idfond, libiroh_c_ffi dylib).
#
# Usage:
#   scripts/build-npm.sh          # host target (what CI runs: one runner per target)
#   scripts/build-npm.sh TARGET   # cross build:
#                                   x86_64-apple-darwin / aarch64-apple-darwin
#                                     (native macOS SDK cross, no extra tools)
#                                   x86_64-unknown-linux-gnu / aarch64-unknown-linux-gnu
#                                     (cargo zigbuild; brew install zig cargo-zigbuild)
#
# RUSTFLAGS keep the dylib's install name @executable_path-relative (macOS) or
# give idfond an $ORIGIN rpath (Linux) so the daemon finds the dylib shipped
# next to it in bin/.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

host=$(rustc -vV | sed -n 's/^host: //p')
target=${1:-$host}
if [ "$target" != "$host" ]; then
  rustup target add "$target"
fi

case "$target" in
  aarch64-apple-darwin) pkg=idfon-darwin-arm64; dylib=libiroh_c_ffi.dylib ;;
  x86_64-apple-darwin) pkg=idfon-darwin-x64; dylib=libiroh_c_ffi.dylib ;;
  x86_64-unknown-linux-gnu) pkg=idfon-linux-x64; dylib=libiroh_c_ffi.so ;;
  aarch64-unknown-linux-gnu) pkg=idfon-linux-arm64; dylib=libiroh_c_ffi.so ;;
  *)
    echo "build-npm.sh: unsupported target: $target" >&2
    exit 1
    ;;
esac

# $build / $cross_flag are intentionally word-split (POSIX sh has no arrays).
cross_flag=""
build="cargo build"
if [ "$target" != "$host" ]; then
  cross_flag="--target $target"
  case "$target" in
    *linux-gnu)
      # Linux cross-links need zig as the linker; macOS cross uses the host SDK.
      # ponytail: zig alone can't satisfy Linux C deps (cpal → pipewire/alsa
      # headers via pkg-config) — building linux targets from a mac needs a
      # Linux sysroot (docker-based cargo-zigbuild image) or a native Linux
      # machine/runner, where the apt deps are installed by CI.
      command -v cargo-zigbuild >/dev/null 2>&1 || {
        echo "build-npm.sh: linux cross needs cargo-zigbuild (brew install zig cargo-zigbuild)" >&2
        exit 1
      }
      build="cargo zigbuild"
      ;;
  esac
fi

# 1. Vendored dylib (the thin idfond links it; see crates/idfond/build.rs).
case "$target" in
  *apple-darwin)
    # /usr/lib/swift rpath: x86_64 capture-stack deps autolink @rpath/libswift*;
    # dyld resolves them from the dyld shared cache. Harmless on arm64.
    RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib -C link-arg=-Wl,-rpath,/usr/lib/swift" \
      $build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml $cross_flag
    ;;
  *linux-gnu)
    RUSTFLAGS="-C link-arg=-Wl,-soname,libiroh_c_ffi.so" \
      $build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml $cross_flag
    ;;
esac

# 2. Daemon + CLI.
if [ -n "$cross_flag" ]; then
  out="target/$target/release"
else
  out="target/release"
fi
case "$target" in
  *apple-darwin)
    $build --release -p idfond -p idfon-cli $cross_flag
    # A relink can leave an ad-hoc signature that no longer matches the pages;
    # the kernel then SIGKILLs the process at exec ("Code Signature Invalid").
    codesign --force -s - "$out/$dylib" "$out/idfond"
    ;;
  *linux-gnu)
    RUSTFLAGS='-C link-arg=-Wl,-rpath,$ORIGIN' \
      $build --release -p idfond -p idfon-cli $cross_flag
    ;;
esac

pkgdir="$root/npm/$pkg"
mkdir -p "$pkgdir/bin"
cp "$out/idfon" "$out/idfond" "$out/$dylib" "$pkgdir/bin/"
echo "build-npm.sh: populated $pkgdir/bin ($target)"
