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

all_agents() {
  local directory candidate
  for directory in "$root"/agents/*; do
    [[ -d "$directory" ]] || continue
    candidate=${directory##*/}
    printf '%s ' "$candidate"
  done
}

usage() {
  printf 'Usage: pnpm agent {start|stop|restart|build|clean} <name|all>\nServed agents: %s\n' "$(available_agents)" >&2
  exit 2
}

[[ "$action" == start || "$action" == stop || "$action" == restart || "$action" == build || "$action" == clean ]] || usage
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || usage

# 'all' fans out to every agent: build/clean cover every agents/<name> dir,
# start/stop/restart cover the served subset (those with a *-serve.sh).
if [[ "$name" == all ]]; then
  case "$action" in
    build|clean) targets=$(all_agents) ;;
    *) targets=$(available_agents) ;;
  esac
  status=0
  for target in $targets; do
    bash "$0" "$action" "$target" || status=1
  done
  exit "$status"
fi

serve="$root/scripts/$name-serve.sh"
if [[ "$action" == build || "$action" == clean ]]; then
  [[ -d "$root/agents/$name" ]] || {
    echo "no agent '$name' under agents/" >&2
    usage
  }
else
  [[ -d "$root/agents/$name" && -f "$serve" ]] || {
    echo "no serve script registered for agent '$name'" >&2
    usage
  }
fi

agent_dir="$root/agents/$name"

if [[ "$action" == build ]]; then
  eve="$agent_dir/node_modules/.bin/eve"
  if [[ ! -x "$eve" ]]; then
    echo "skipped $name: no installed eve (run npm install in agents/$name)" >&2
    exit 0
  fi
  (cd "$agent_dir" && "$eve" build)
  exit 0
fi

if [[ "$action" == clean ]]; then
  rm -rf "$agent_dir/.output" "$agent_dir/dist"
  echo "cleaned $name"
  exit 0
fi

if [[ "$action" == restart ]]; then
  bash "$0" stop "$name" || true
  action=start
fi

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
