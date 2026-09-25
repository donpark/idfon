#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
action=${1:-}
name=${2:-}

available_agents() {
  local directory candidate
  for directory in "$root"/agents/*; do
    [[ -d "$directory" ]] || continue
    candidate=${directory##*/}
    [[ -f "$root/scripts/$candidate-serve.sh" ]] && printf '%s ' "$candidate"
  done
}

usage() {
  printf 'Usage: pnpm agent {start|stop} <name>\nServed agents: %s\n' "$(available_agents)" >&2
  exit 2
}

[[ "$action" == start || "$action" == stop ]] || usage
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || usage

serve="$root/scripts/$name-serve.sh"
[[ -d "$root/agents/$name" && -f "$serve" ]] || {
  echo "no serve script registered for agent '$name'" >&2
  usage
}

home=${EVE_VOICE_HOME:-"$HOME/.idfon/$name"}
pidfile="$home/serve.pid"
logfile="$home/serve-manager.log"
mkdir -p "$home"

is_serve_process() {
  local command
  command=$(ps -p "$1" -o command= 2>/dev/null || true)
  [[ "$command" == *"$serve"* || "$command" == *"${name}-serve.sh"* ]]
}

if [[ "$action" == start ]]; then
  if [[ -r "$pidfile" ]]; then
    read -r pid < "$pidfile"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      if is_serve_process "$pid"; then
        echo "$name already running (pid $pid)"
        exit 0
      fi
      echo "refusing to replace $pidfile: pid $pid is not $serve" >&2
      exit 1
    fi
    rm -f "$pidfile"
  fi

  nohup bash "$serve" >>"$logfile" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$pidfile"
  sleep 0.5
  if ! kill -0 "$pid" 2>/dev/null || ! is_serve_process "$pid"; then
    rm -f "$pidfile"
    echo "$name failed to start; see $logfile" >&2
    exit 1
  fi
  echo "started $name (pid $pid); log: $logfile"
else
  if [[ ! -r "$pidfile" ]]; then
    echo "$name is not managed by 'pnpm agent'" >&2
    exit 1
  fi
  read -r pid < "$pidfile"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "invalid pid in $pidfile" >&2
    exit 1
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pidfile"
    echo "$name was not running (removed stale pid file)"
    exit 0
  fi
  if ! is_serve_process "$pid"; then
    echo "refusing to stop pid $pid: it is not $serve" >&2
    exit 1
  fi

  kill -TERM "$pid"
  for _ in $(seq 1 100); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pidfile"
      echo "stopped $name"
      exit 0
    fi
    sleep 0.1
  done
  echo "$name did not stop; pid file retained at $pidfile" >&2
  exit 1
fi
