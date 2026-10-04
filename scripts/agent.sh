#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
action=${1:-}
spec=${2:-}

# An agent backs one or more *instances*; each instance is a distinct contact
# identity (its own home under ~/.idfon/<instance>, key, and ports). Address an
# instance as `<agent>:<instance>`; a bare `<agent>` means its default instance
# (EVE_INSTANCE defaults to the agent name).
agent=${spec%%:*}
instance=""
if [[ "$spec" == *:* ]]; then instance=${spec#*:}; fi

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

# Directories under ~/.idfon that look like an instance home.
instance_dirs() {
  local dir
  for dir in "$HOME"/.idfon/*/; do
    [[ -d "$dir" ]] || continue
    if [[ -f "$dir/instance.env" || -f "$dir/holder.key" || -f "$dir/serve.pid" \
       || -f "$dir/holder.pid" || -f "$dir/endpoint-port" ]]; then
      printf '%s\n' "$dir"
    fi
  done
  return 0
}

# Best-effort agent name for an instance home: persisted env, then the
# instance name itself when it is an agent, then a running serve manager's
# command line. Empty when it cannot be determined.
instance_agent() {
  local dir="$1" inst="$2" found=""
  if [[ -f "$dir/instance.env" ]]; then
    found=$(sed -n "s/^export EVE_AGENT=//p" "$dir/instance.env" | tail -1 | tr -d "\"'")
  fi
  if [[ -z "$found" && -d "$root/agents/$inst" ]]; then found="$inst"; fi
  if [[ -z "$found" && -r "$dir/serve.pid" ]]; then
    local pid; pid=$(cat "$dir/serve.pid")
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      found=$(ps -p "$pid" -o command= 2>/dev/null | grep -oE '[a-z0-9-]+-serve\.sh' | head -1 | sed 's/-serve\.sh$//')
    fi
  fi
  printf '%s' "$found"
}

# Non-default instances, as `agent:instance` (the default instance, dir ==
# agent, is covered by the bare agent name).
discover_instances() {
  local dir inst found_agent
  while IFS= read -r dir; do
    inst=${dir%/}; inst=${inst##*/}
    found_agent=$(instance_agent "$dir" "$inst")
    [[ -n "$found_agent" ]] || continue
    [[ "$inst" == "$found_agent" ]] && continue
    [[ -f "$root/scripts/$found_agent-serve.sh" ]] || continue
    printf '%s:%s\n' "$found_agent" "$inst"
  done < <(instance_dirs)
  return 0
}

list_instances() {
  printf '%-18s %-12s %-7s %-8s %s\n' INSTANCE AGENT PID STATUS DETAIL
  local dir inst found_agent pid status detail model contact
  while IFS= read -r dir; do
    inst=${dir%/}; inst=${inst##*/}
    found_agent=$(instance_agent "$dir" "$inst")
    [[ -n "$found_agent" ]] || found_agent="?"
    model=""; contact=""
    if [[ -f "$dir/instance.env" ]]; then
      model=$(sed -n "s/^export EVE_IDFON_MODEL=//p" "$dir/instance.env" | tail -1 | tr -d "\"'")
      contact=$(sed -n "s/^export EVE_CONTACT_NAME=//p" "$dir/instance.env" | tail -1 | tr -d "\"'")
    fi
    pid=""
    if [[ -r "$dir/serve.pid" ]]; then pid=$(cat "$dir/serve.pid"); fi
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      status=running
    else
      status=stopped; pid=""
    fi
    detail="${contact:+$contact }${model:-}"
    printf '%-18s %-12s %-7s %-8s %s\n' "$inst" "$found_agent" "${pid:--}" "$status" "$detail"
  done < <(instance_dirs)
  return 0
}

usage() {
  printf 'Usage: pnpm agent {start|stop|restart|kill|build|clean|list} <name|all>\n' >&2
  printf '  <name> is <agent> or <agent>:<instance> (e.g. llm:gemini38).\n' >&2
  printf 'Served agents: %s\n' "$(available_agents)" >&2
  printf 'All agents (build/clean): %s\n' "$(all_agents)" >&2
  printf 'Instances on disk: %s\n' "$(discover_instances | tr '\n' ' ')" >&2
  exit 2
}

if [[ "$action" == list ]]; then
  list_instances
  exit 0
fi

[[ "$action" == start || "$action" == stop || "$action" == restart || "$action" == kill || "$action" == build || "$action" == clean ]] || usage
[[ "$spec" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*(:[a-zA-Z0-9][a-zA-Z0-9_-]*)?$ ]] || usage

# 'all' fans out to every agent directory plus every non-default instance.
# build/clean touch all agents; lifecycle actions cover the served ones (others
# are reported as skipped, not silently ignored).
if [[ "$spec" == all ]]; then
  status=0
  if [[ "$action" == build || "$action" == clean ]]; then
    targets=$(all_agents)
  else
    targets=$( { available_agents | tr ' ' '\n'; discover_instances; } | sort -u | tr '\n' ' ' )
  fi
  for target in $targets; do
    [[ -n "$target" ]] || continue
    bash "$0" "$action" "$target" || status=1
  done
  exit "$status"
fi

serve="$root/scripts/$agent-serve.sh"
if [[ "$action" == build || "$action" == clean ]]; then
  [[ -d "$root/agents/$agent" ]] || {
    echo "no agent '$agent' under agents/" >&2
    usage
  }
else
  [[ -d "$root/agents/$agent" && -f "$serve" ]] || {
    echo "no serve script registered for agent '$agent'" >&2
    usage
  }
fi

agent_dir="$root/agents/$agent"
resolved_instance=${instance:-$agent}
home=${EVE_VOICE_HOME:-"$HOME/.idfon/$resolved_instance"}
env_file="$home/instance.env"
pidfile="$home/serve.pid"
logfile="$home/serve-manager.log"

if [[ "$action" == build ]]; then
  eve="$agent_dir/node_modules/.bin/eve"
  if [[ ! -x "$eve" ]]; then
    echo "skipped $agent: no installed eve (run npm install in agents/$agent)" >&2
    exit 0
  fi
  (cd "$agent_dir" && "$eve" build)
  exit 0
fi

if [[ "$action" == clean ]]; then
  rm -rf "$agent_dir/.output" "$agent_dir/dist"
  echo "cleaned $agent"
  exit 0
fi

mkdir -p "$home"

# Replay a persisted instance config so `restart llm:gemini38` needs no env;
# values exported by the caller still win.
replay_instance_env() {
  [[ -f "$env_file" ]] || return 0
  local caller
  caller=$(env | grep -E '^(EVE_|IDFON_)' || true)
  # shellcheck disable=SC1090
  source "$env_file"
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then export "$line"; fi
  done <<< "$caller"
  return 0
}

persist_instance_env() {
  local var val
  : > "$env_file"
  for var in EVE_AGENT EVE_INSTANCE EVE_CONTACT_NAME EVE_IDFON_MODEL \
             EVE_LIVE_CONFIG EVE_VOICE_PORT EVE_VOICE_HOME EVE_IDFON_PKG \
             EVE_IDFON_BIN EVE_IDFON_FEATURES IDFON_BRIDGE_SECRET IDFON_SOCKET IDFON_CLI; do
    val="${!var-}"
    if [[ -n "$val" ]]; then printf 'export %s=%q\n' "$var" "$val" >> "$env_file"; fi
  done
  return 0
}

is_serve_process() {
  local command
  command=$(ps -p "$1" -o command= 2>/dev/null || true)
  [[ "$command" == *"$serve"* || "$command" == *"${agent}-serve.sh"* ]]
}

if [[ "$action" == restart ]]; then
  bash "$0" stop "$spec" || true
  action=start
fi

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
    echo "$resolved_instance is not running"
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
  echo "killed $resolved_instance (${#pids[@]} process(es))"
  exit 0
fi

if [[ "$action" == start ]]; then
  if [[ -r "$pidfile" ]]; then
    read -r pid < "$pidfile"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      if is_serve_process "$pid"; then
        echo "$resolved_instance already running (pid $pid)"
        exit 0
      fi
      echo "refusing to replace $pidfile: pid $pid is not $serve" >&2
      exit 1
    fi
    rm -f "$pidfile"
  fi

  replay_instance_env
  export EVE_AGENT="$agent"
  export EVE_INSTANCE="$resolved_instance"
  persist_instance_env

  nohup bash "$serve" >>"$logfile" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$pidfile"
  sleep 0.5
  if ! kill -0 "$pid" 2>/dev/null || ! is_serve_process "$pid"; then
    rm -f "$pidfile"
    echo "$resolved_instance failed to start; see $logfile" >&2
    exit 1
  fi
  echo "started $resolved_instance (pid $pid); log: $logfile"
else
  if [[ ! -r "$pidfile" ]]; then
    echo "$resolved_instance is not running (not managed by 'pnpm agent')"
    exit 0
  fi
  read -r pid < "$pidfile"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "invalid pid in $pidfile" >&2
    exit 1
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pidfile"
    echo "$resolved_instance was not running (removed stale pid file)"
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
      echo "stopped $resolved_instance"
      exit 0
    fi
    sleep 0.1
  done
  echo "$resolved_instance did not stop; pid file retained at $pidfile" >&2
  exit 1
fi
