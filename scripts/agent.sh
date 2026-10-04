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
  printf 'Usage: pnpm agent {start|stop|restart|kill|build|clean} <name|all>\n' >&2
  printf 'Served agents: %s\n' "$(available_agents)" >&2
  printf 'All agents (build/clean): %s\n' "$(all_agents)" >&2
  exit 2
}

[[ "$action" == start || "$action" == stop || "$action" == restart || "$action" == kill || "$action" == build || "$action" == clean ]] || usage
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || usage

# 'all' fans out to every agent directory. build/clean touch all of them;
# start/stop/restart/kill cover the ones with a serve script (others are
# reported as skipped, not silently ignored).
if [[ "$name" == all ]]; then
  status=0
  for target in $(all_agents); do
    if [[ "$action" != build && "$action" != clean && ! -f "$root/scripts/$target-serve.sh" ]]; then
      echo "skipped $target: no serve script" >&2
      continue
    fi
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

if [[ "$action" == kill ]]; then
  # Force-stop the manager *and* its children (holder/bridge/eve), which a
  # SIGKILL on the manager would otherwise orphan — the serve scripts kill
  # them via a TERM trap, which -9 skips.
  pids=()
  if [[ -r "$pidfile" ]]; then
    read -r pid < "$pidfile"
    [[ "$pid" =~ ^[0-9]+$ ]] && pids+=("$pid")
  fi
  while IFS= read -r child; do
    pids+=("$child")
  done < <(pgrep -f "$home/" 2>/dev/null || true)
  if [[ ${#pids[@]} -eq 0 ]]; then
    rm -f "$pidfile"
    echo "$name is not running"
    exit 0
  fi
  kill -9 ${pids[@]+"${pids[@]}"} 2>/dev/null || true
  for _ in $(seq 1 20); do
    alive=0
    for pid in ${pids[@]+"${pids[@]}"}; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [[ "$alive" -eq 0 ]] && break
    sleep 0.1
  done
  rm -f "$pidfile"
  echo "killed $name (${#pids[@]} process(es))"
  exit 0
fi

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
