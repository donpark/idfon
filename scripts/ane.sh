#!/usr/bin/env bash
# ane — list and clean the disk leftovers of Core AI / ANE model loads.
#
#   pnpm ane list            what we left behind indirectly, with sizes
#   pnpm ane clean           sweep stale scratch + prune stale cache registrations
#   pnpm ane clean -- --flush   also try the ANE daemon flush (needs sudo)
#
# What "left behind" means: every runtime load of a source .aimodel makes the
# runtime attempt an ANE compile. The attempt leaves a mpsgraph-* workdir (or a
# *_main.ir dump) in TMPDIR and registers a copy in ~/Library/Caches/coreai-cache.
# The daemon ANE caches (/Library/Caches/com.apple.aned and friends) grow the
# same way but are datavault-locked: only sudo or a reboot reaches them.
# Details: docs/disk-hygiene.md.
#
# Output contract (for scripts and agents): stdout is line-oriented records,
# key=value pairs separated by single spaces. Lines start with "kind=" (one
# leftover) or "summary" (one aggregate line). Human notes go to stderr.
# Exit codes: 0 ok, 1 measurement failed, 2 bad usage.
#
# Measurement rule: judge reclaims by the summary's df numbers, never by du —
# du over-counts APFS clones (2026-10-27 lesson).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/bench-results/coreai"
CACHE="$HOME/Library/Caches/coreai-cache"
TMP="${TMPDIR:-/tmp}"
SCRATCH="$TMP/com.apple.MetalPerformanceShadersGraph"
# Age gate: a compile in flight is never touched (same rule as the apps'
# ScratchSweep and export_turn.py's scratch_sweep).
MAX_AGE_S=3600

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

avail_kb() {
  df -k /System/Volumes/Data | awk 'NR==2 {print $4}'
}

# The current assets' main.hash values (source + compiled) — a cache
# registration is live when its hash is in this set.
live_hashes() {
  find "$ASSETS" -name main.hash | while read -r f; do
    xxd -ps "$f" | tr -d '\n'; echo
  done | tr 'a-f' 'A-F' | sort -u
}

# Cache registration dirs: <build>/<identity>/<hash> and unknown/<hash>.
cache_dirs() {
  find "$CACHE" -maxdepth 3 -type d \( -path "$CACHE/26A434/*/*" -o -path "$CACHE/unknown/*" \) 2>/dev/null
}

kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
age_s() { echo $(( $(date +%s) - $(stat -f %m "$1") )); }

cmd_list() {
  local live scratch_items=0 scratch_kb=0 cache_items=0 cache_kb=0 cache_stale=0 daemon=0
  live="$(live_hashes)"
  local t
  for t in "$SCRATCH"/* "$TMP"/*_main.ir; do
    [ -e "$t" ] || continue
    local b a
    b="$(kb "$t")"; a="$(age_s "$t")"
    echo "kind=scratch path=$t bytes=$((b * 1024)) age_s=$a"
    scratch_items=$((scratch_items + 1)); scratch_kb=$((scratch_kb + b))
  done
  local dir h ident b status
  while read -r dir; do
    [ -n "$dir" ] || continue
    h="$(basename "$dir" | tr 'a-f' 'A-F')"
    # Registrations are the 64-hex-named dirs; skip their *.aimodel kids.
    [[ "$h" =~ ^[0-9A-F]{64}$ ]] || continue
    ident="$(basename "$(dirname "$dir")")"
    b="$(kb "$dir")"
    status=prune
    grep -qx "$h" <<<"$live" && status=keep
    # The unknown bucket is keyed by a runtime-internal hash we cannot derive
    # from the assets, and the next load recreates it — young ones stay (the
    # same 14-day rule coreai-cache-prune.sh applies).
    case "$dir" in
      */unknown/*)
        [ -n "$(find "$dir" -maxdepth 0 -mtime -14)" ] && status=keep ;;
    esac
    echo "kind=cache path=$dir identity=$ident hash=$h bytes=$((b * 1024)) status=$status"
    cache_items=$((cache_items + 1)); cache_kb=$((cache_kb + b))
    [ "$status" = prune ] && cache_stale=$((cache_stale + 1))
  done < <(cache_dirs)
  for t in /Library/Caches/com.apple.aned \
           /Library/Caches/com.apple.aneuserd \
           /Library/Caches/com.apple.amsengagementd.classicdatavault; do
    echo "kind=daemon-cache path=$t bytes=unknown note=stat-denied-datavault"
    daemon=$((daemon + 1))
  done
  echo "summary scratch_items=$scratch_items scratch_kb=$scratch_kb cache_items=$cache_items cache_kb=$cache_kb cache_stale=$cache_stale daemon_caches=$daemon"
}

cmd_clean() {
  local flush=0
  for a in "$@"; do
    case "$a" in
      --flush|flush) flush=1 ;;
      *) usage ;;
    esac
  done
  [ "${ANE_FLUSH:-0}" = 1 ] && flush=1

  local before after swept=0 pruned=0 t
  before="$(avail_kb)"
  for t in "$SCRATCH"/* "$TMP"/*_main.ir; do
    [ -e "$t" ] || continue
    [ "$(age_s "$t")" -gt "$MAX_AGE_S" ] || continue
    rm -rf "$t"
    swept=$((swept + 1))
  done
  # The prune script owns the keep-rule (a registration stays when its hash
  # matches a current asset's main.hash). Its listing is human detail: stderr.
  local out
  out="$(bash "$ROOT/scripts/coreai-cache-prune.sh" "$ASSETS")"
  echo "$out" >&2
  pruned="$(grep -o 'pruned [0-9]*' <<<"$out" | awk '{print $2}' || true)"
  pruned="${pruned:-0}"

  local aned=skipped
  if [ "$flush" = 1 ]; then
    if sudo killall aned aneuserd; then aned=done; else aned=failed; fi
  elif sudo -n killall aned aneuserd 2>/dev/null; then
    aned=done
  else
    echo "ANE daemon flush skipped: no passwordless sudo. Run 'pnpm ane clean -- --flush' in a Terminal, or: sudo killall aned aneuserd" >&2
  fi

  sleep 3
  after="$(avail_kb)"
  echo "summary scratch_swept=$swept cache_pruned=$pruned aned_flush=$aned avail_kb_before=$before avail_kb_after=$after freed_kb=$((after - before))"
}

case "${1:-}" in
  list) shift; [ $# = 0 ] || usage; cmd_list ;;
  clean) shift; cmd_clean "$@" ;;
  *) usage ;;
esac
