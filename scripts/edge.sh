#!/usr/bin/env bash
# Build idfon-edge: the Rust binary, or the deployable container image
# (deploy/idfon-edge/Dockerfile — what .github/workflows/edge.yml publishes
# to ghcr.io as ghcr.io/donpark/idfon-edge).
#
#   pnpm edge build
#   pnpm edge image
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
action=${1:-}

case "$action" in
  build)
    shift
    exec cargo build --release -p idfon-edge "$@"
    ;;
  image)
    shift
    exec docker build -f "$root/deploy/idfon-edge/Dockerfile" -t idfon-edge "$root" "$@"
    ;;
  *)
    printf 'Usage: pnpm edge {build|image}\n' >&2
    exit 2
    ;;
esac
