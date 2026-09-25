#!/usr/bin/env bash
# Build or clean every Eve artifact: the eve-idfon-channel extension first, then
# every agent (agents get the extension's freshly built dist via the workspace
# link, so the extension must come first).
#
#   pnpm eve build
#   pnpm eve clean
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
action=${1:-}

case "$action" in
  build|clean) ;;
  *)
    printf 'Usage: pnpm eve {build|clean}\n' >&2
    exit 2
    ;;
esac

pnpm --filter eve-idfon-channel "$action"
bash "$root/scripts/agent.sh" "$action" all
