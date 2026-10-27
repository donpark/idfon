#!/usr/bin/env bash
# Prune stale CoreAI cache registrations in ~/Library/Caches/coreai-cache.
# Every model load registers a copy per process identity (app, python, xctest).
# A re-export changes the model hash and orphans the previous registration —
# the "leaked assets" of 2026-10-27. Keep rule: a registration stays when its
# hash matches a current asset's main.hash. Deletion is cache-only: a live miss
# re-registers on the next load.
# Usage: coreai-cache-prune.sh [assets-dir]   (default bench-results/coreai)
# Judge the reclaim by df deltas, never by du — du over-counts APFS clones.
set -euo pipefail
ROOT="${1:-$HOME/dev/idfon/bench-results/coreai}"
CACHE="$HOME/Library/Caches/coreai-cache"
live=$(find "$ROOT" -name main.hash | while read -r f; do xxd -ps "$f" | tr -d '\n'; echo; done | tr 'a-f' 'A-F' | sort -u)
pruned=0
for dir in "$CACHE"/26A434/*/*/ "$CACHE"/unknown/*/; do
  [ -d "$dir" ] || continue
  h=$(basename "$dir" | tr 'a-f' 'A-F')
  # The `unknown` bucket is keyed by a runtime-internal hash we cannot derive
  # from the assets, and the next load recreates it: keep young entries (no
  # churn), prune anything untouched for two weeks.
  case "$dir" in
    */unknown/*)
      [ -n "$(find "$dir" -maxdepth 0 -mtime -14)" ] && continue ;;
  esac
  if ! grep -qx "$h" <<<"$live"; then
    echo "prune $dir"
    rm -rf "$dir"
    pruned=$((pruned + 1))
  fi
done
echo "pruned $pruned stale registrations"
