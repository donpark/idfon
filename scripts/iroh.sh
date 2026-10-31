#!/usr/bin/env bash
# Build or clean the iroh C FFI dylib (libiroh_c_ffi): the single C-ABI library
# the native shells and idfond link. Build it before idfond — idfond's
# build.rs links the release dylib (docs/build.md).
#
#   pnpm iroh build
#   pnpm iroh clean
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
action=${1:-}

case "$action" in
  build)
    cargo build --release -p iroh-c-ffi
    # Ad-hoc sign after relink, or the kernel SIGKILLs at exec (macOS).
    if command -v codesign >/dev/null 2>&1; then
      codesign --force -s - target/release/libiroh_c_ffi.dylib
    fi
    ;;
  clean)
    cargo clean -p iroh-c-ffi
    ;;
  *)
    echo "usage: pnpm iroh {build|clean}" >&2
    exit 1
    ;;
esac
