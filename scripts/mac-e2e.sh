#!/bin/bash
# On-mac automation for the flows that can't be checked headlessly — no
# simulator, no device. Drives the *real* attachment path via `-sendfile` (see
# mac/Sources/Idfon/Automation.swift) and asserts the Session Tray / transfer
# markers from the app's console.
#
#   scripts/mac-e2e.sh --peer <peer-ref> --file <path> [--timeout 60] [--no-build]
#
#   --peer      peer ref/name/id to send to (or $PEER)
#   --file      local file to send (absolute path is passed to the app)
#   --timeout   seconds to wait for the transfer to finish (default 60)
#   --no-build  reuse the already-built app bundle
#
# Needs a reachable peer (the paired iOS app, or another idfon endpoint). The
# app spawns idfond itself if one isn't already running. The peer side is not
# asserted here — watch its console for `idfon file: received`.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin="$root/mac/build/Idfon.app/Contents/MacOS/Idfon"
bundle_id=app.idfon.mac

peer="${PEER:-}"
file=""
timeout_s=60
build=1

usage() { sed -n '2,16p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --peer) peer="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --timeout) timeout_s="$2"; shift 2 ;;
    --no-build) build=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$peer" ] || { echo "need --peer <peer-ref>" >&2; exit 2; }
[ -n "$file" ] || { echo "need --file <path>" >&2; exit 2; }
[ -f "$file" ] || { echo "no such file: $file" >&2; exit 2; }

if [ "$build" = 1 ]; then
  echo "== building (mac/build.sh)"
  bash "$root/mac/build.sh"
fi
[ -x "$bin" ] || { echo "app not built at $bin (drop --no-build)" >&2; exit 2; }

abs=$(cd "$(dirname "$file")" && pwd)/$(basename "$file")
log=$(mktemp /tmp/idfon-mac-e2e.XXXXXX)
echo "== launching -sendfile $peer $(basename "$file") (timeout ${timeout_s}s, log $log)"
"$bin" -sendfile "$peer" "$abs" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

# Stop as soon as the tray row finishes, or when the app dies / times out.
deadline=$(( $(date +%s) + timeout_s ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  kill -0 "$pid" 2>/dev/null || break
  if grep -q "idfon tray: finish" "$log" 2>/dev/null; then break; fi
  sleep 1
done
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

echo "== markers"
fail=0
for marker in \
  "idfon-auto: sendfile start" \
  "idfon tray: begin" \
  "idfon file: sent" \
  "idfon tray: finish"
do
  if grep -qF "$marker" "$log"; then
    echo "ok:   $marker"
  else
    echo "FAIL: missing '$marker'"
    fail=1
  fi
done

echo "== console (idfon lines)"
grep -E "idfon-auto:|idfon tray:|idfon file:" "$log" | tail -20 || true

if [ "$fail" != 0 ]; then
  echo "FAILED — full console: $log"
  exit 1
fi
echo "PASS — peer should log 'idfon file: received' ($bundle_id)"
