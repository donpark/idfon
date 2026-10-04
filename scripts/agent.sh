#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
action=${1:-}
name=${2:-}

# An *agent* is an identity + config + process (one home, one identity, one
# pinned port). Callers are *sessions*: runtime-only, created on their first
# turn and gone when the agent stops. Multi-model contacts (the agency roster)
# are separate configured runs of an agent, owned by that feature — not
# managed here.
available_agents() {
  local directory candidate
  for directory in "$root"/agents/*; do
    [[ -d "$directory" ]] || continue
    candidate=${directory##*/}
    [[ -f "$root/scripts/$candidate-serve.sh" ]] && printf '%s ' "$candidate"
  done
  return 0
}

all_agents() {
  local directory candidate
  for directory in "$root"/agents/*; do
    [[ -d "$directory" ]] || continue
    candidate=${directory##*/}
    printf '%s ' "$candidate"
  done
  return 0
}

agent_home() { printf '%s' "${EVE_VOICE_HOME:-$HOME/.idfon/$1}"; }

# Voice mode the agent advertises: `voice_route.mode` from its live config,
# else client-cascade (no live config).
agent_mode() {
  local live="$root/agents/$1/live.json" mode=""
  if [[ -f "$live" ]]; then
    mode=$(jq -r '.voice_route.mode // empty' "$live" 2>/dev/null || true)
    [[ -n "$mode" ]] || mode=$(jq -r '.backend // empty' "$live" 2>/dev/null || true)
  fi
  printf '%s' "${mode:-client-cascade}"
}

list_agents() {
  printf '%-14s %-7s %-8s %-6s %-16s %s\n' AGENT PID STATUS PORT MODE HOME
  local agent home pid status port
  for agent in $(all_agents); do
    home=$(agent_home "$agent")
    port="-"; [[ -s "$home/endpoint-port" ]] && port=$(cat "$home/endpoint-port")
    pid=""
    [[ -r "$home/serve.pid" ]] && pid=$(cat "$home/serve.pid")
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      status=running
    else
      pid=$(pgrep -f "$root/scripts/$agent-serve.sh" 2>/dev/null | head -1 || true)
      if [[ -n "$pid" ]]; then status="running*"; else status=stopped; pid=""; fi
    fi
    printf '%-14s %-7s %-8s %-6s %-16s %s\n' \
      "$agent" "${pid:--}" "$status" "$port" "$(agent_mode "$agent")" "$home"
  done
  printf '\n  running* = serving, but not started by pnpm agent\n'
  return 0
}

usage() {
  printf 'Usage: pnpm agent {start|stop|restart|kill|build|clean|list} <agent|all>\n' >&2
  printf 'Served agents: %s\n' "$(available_agents)" >&2
  printf 'All agents:    %s\n' "$(all_agents)" >&2
  exit 2
}

if [[ "$action" == list ]]; then
  list_agents
  exit 0
fi

[[ "$action" == start || "$action" == stop || "$action" == restart || "$action" == kill || "$action" == build || "$action" == clean ]] || usage
[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || usage

if [[ "$name" == all ]]; then
  status=0
  if [[ "$action" == build || "$action" == clean ]]; then
    targets=$(all_agents)
  else
    targets=$(available_agents)
  fi
  for target in $targets; do
    bash "$0" "$action" "$target" || status=1
  done
  exit "$status"
fi

serve="$root/scripts/$name-serve.sh"
if [[ "$action" == build || "$action" == clean ]]; then
  [[ -d "$root/agents/$name" ]] || { echo "no agent '$name' under agents/" >&2; usage; }
else
  [[ -d "$root/agents/$name" && -f "$serve" ]] || { echo "no serve script registered for agent '$name'" >&2; usage; }
fi

agent_dir="$root/agents/$name"
home=$(agent_home "$name")
pidfile="$home/serve.pid"
logfile="$home/serve-manager.log"

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

mkdir -p "$home"

is_serve_process() {
  local command
  command=$(ps -p "$1" -o command= 2>/dev/null || true)
  [[ "$command" == *"$serve"* || "$command" == *"${name}-serve.sh"* ]]
}

if [[ "$action" == restart ]]; then
  bash "$0" stop "$name" || true
  action=start
fi

if [[ "$action" == kill ]]; then
  # Force-stop the manager *and* the holder/bridge/eve children a SIGKILL on
  # the manager would otherwise orphan.
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

  export EVE_AGENT="$name"
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
    echo "$name is not running (not managed by 'pnpm agent')"
    exit 0
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
