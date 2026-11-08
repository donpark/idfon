#!/usr/bin/env bash
# Run the test-contacts page (scripts/test-contacts-page.mjs): every contact
# this machine serves, one tap away on the phone.
#
#   pnpm test-contacts start [--port 9000] [--only llm,radio-tech]
#   pnpm test-contacts stop
#   pnpm test-contacts restart
#   pnpm test-contacts build    static snapshot of the page (codes inert without start)
#   pnpm test-contacts clean    stop + remove pid/log/snapshot
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
action=${1:-}
shift || true

run=/tmp/idfon-test-contacts   # scratch only: pid, serve log, static snapshot

pid_of() { [ -s "$run/pid" ] && cat "$run/pid" || true; }
running() { local p; p=$(pid_of); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

stop() {
  local p; p=$(pid_of)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    kill "$p"
    for _ in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$p" 2>/dev/null || true
    echo "test-contacts: stopped pid $p"
  fi
  rm -f "$run/pid"
}

start() {
  if running; then
    echo "test-contacts: already running (pid $(pid_of)); use restart to pick up new args" >&2
    exit 1
  fi
  mkdir -p "$run"
  : >"$run/serve.log"
  nohup node scripts/test-contacts-page.mjs --serve "$@" >"$run/serve.log" 2>&1 &
  echo $! >"$run/pid"
  for _ in $(seq 1 50); do
    grep -q 'on http' "$run/serve.log" 2>/dev/null && break
    running || { cat "$run/serve.log" >&2; exit 1; }
    sleep 0.1
  done
  cat "$run/serve.log"
}

case "$action" in
  start)   start "$@" ;;
  stop)    stop ;;
  restart) stop; start "$@" ;;
  build)
    mkdir -p "$run"
    node scripts/test-contacts-page.mjs --out "$run/page.html" "$@"
    ;;
  clean)    stop; rm -rf "$run" ;;
  *)
    printf 'Usage: pnpm test-contacts {start|stop|restart|build|clean} [args for --serve/--out]\n' >&2
    exit 2
    ;;
esac