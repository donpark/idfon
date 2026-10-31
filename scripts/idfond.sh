#!/usr/bin/env bash
# Build the idfond daemon binary. Needs the release c-FFI dylib first — its
# build.rs links it (docs/build.md): run `pnpm iroh build` before this.
#
#   pnpm idfond build
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
action=${1:-}

case "$action" in
  build)
    cargo build --release -p idfond
    # Ad-hoc sign after relink, or the kernel SIGKILLs at exec (macOS).
    if command -v codesign >/dev/null 2>&1; then
      codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond
    fi
    ;;
  clean)
    cargo clean -p idfond
    # cargo clean -p keeps the linked bin in target/release
    rm -f target/release/idfond
    ;;
  *)
    echo "usage: pnpm idfond {build|clean}" >&2
    exit 1
    ;;
esac
