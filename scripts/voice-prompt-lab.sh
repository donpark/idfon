#!/bin/sh
# Headless voice-agent prompt lab.
#
# Brings up the real stack in a throwaway instance — a temp daemon, the holder
# (with a chosen live config), the eve agent, and the bridge — then sends
# scripted caller turns and prints the replies. No iPhone, no call, no audio:
# this exercises the holder -> agent path and the `instructions`/prompt
# surfaces, so prompt changes iterate in seconds.
#
#   scripts/voice-prompt-lab.sh --turn "what is the capital of France?"
#   scripts/voice-prompt-lab.sh --config agents/llm/live.json --turns turns.txt
#   scripts/voice-prompt-lab.sh --config a.json --config b.json --turn "..."
#
#   --turn TEXT        one caller turn (repeatable)
#   --turns FILE       one caller turn per line ('#' comments ignored)
#   --config FILE      live config to serve (repeatable; default
#                      agents/llm/live.json); one full run per config
#   --agent NAME       agent under agents/ (default llm)
#   --model ID         model id (default $EVE_IDFON_MODEL)
#   --context TEXT     per-turn caller context (default the app's client-cascade line)
#   --timeout SECS     per-reply timeout (default 120)
#   --keep             leave the stack running and print the instance home
#
# Requires AI_GATEWAY_API_KEY in the environment (the agent's model gateway).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

agent=llm
configs=""
turns=""
model="${EVE_IDFON_MODEL:-}"
context="Client cascade (on-device speech). Recognition: Apple Built-in; Generation: Apple Built-in. The holder only produces text."
timeout_s=120
keep=0

usage() { sed -n '2,26p' "$0"; }

add_turn() {
  turns="$turns$1
"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --turn) add_turn "$2"; shift 2 ;;
    --turns) while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        add_turn "$line"
      done < "$2"; shift 2 ;;
    --config) configs="$configs$2
"; shift 2 ;;
    --agent) agent="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --context) context="$2"; shift 2 ;;
    --timeout) timeout_s="$2"; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$turns" ]; then
  echo "no turns: pass --turn TEXT or --turns FILE" >&2
  exit 2
fi

# Default config: the agent's own live.json when it exists.
configs_trimmed=$(printf '%s' "$configs" | sed '/^$/d')
if [ -z "$configs_trimmed" ]; then
  configs_trimmed="agents/$agent/live.json"
fi

cli="$root/target/release/idfon"
serve="$root/scripts/live-voice-serve.sh"

run_config() {
  config=$1
  work=$(mktemp -d /tmp/idfon-voice-lab.XXXXXX)
  socket="$work/idfond.sock"
  home="$work/home"
  mkdir -p "$work/daemon" "$home"

  serve_pid=""
  daemon_pid=""
  cleanup() {
    [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null || true
    [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    [ "$keep" = 1 ] || rm -rf "$work"
  }
  trap cleanup EXIT INT TERM

  "$root/target/release/idfond" --socket "$socket" --data-dir "$work/daemon" \
    >"$work/daemon.log" 2>&1 &
  daemon_pid=$!
  for _ in $(seq 1 150); do
    "$cli" --socket "$socket" status --json >/dev/null 2>&1 && break
    sleep 0.1
  done

  IDFON_SOCKET="$socket" EVE_AGENT="$agent" EVE_INSTANCE="lab-$agent" \
    EVE_VOICE_HOME="$home" EVE_IDFON_MODEL="$model" EVE_LIVE_CONFIG="$config" \
    AI_GATEWAY_API_KEY="${AI_GATEWAY_API_KEY:-}" \
    "$serve" >"$work/serve.log" 2>&1 &
  serve_pid=$!

  for _ in $(seq 1 600); do
    [ -s "$home/holder.ticket" ] && [ -s "$home/capability-ticket.json" ] && break
    if ! kill -0 "$serve_pid" 2>/dev/null; then
      echo "serve failed; log:" >&2; tail -20 "$work/serve.log" >&2; exit 1
    fi
    sleep 0.1
  done

  pid=$(head -1 "$home/holder.ticket" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  addr=$(head -1 "$home/holder.ticket")
  ticket=$(cat "$home/capability-ticket.json")
  "$cli" --socket "$socket" peer add "$pid" --name "lab" --endpoint-id "$pid" \
    --endpoint-addr "$addr" --json >/dev/null 2>&1 || true
  "$cli" --socket "$socket" access allow --subject "$pid" --capability message.send \
    --json >/dev/null 2>&1 || true

  echo "=== config: $config (agent $agent, model ${model:-default}) ==="
  after=""
  # A here-doc (not a pipe) so `after` survives across turns.
  while IFS= read -r text; do
    [ -n "$text" ] || continue
    echo "caller> $text"
    key="lab-$(date +%s)-${RANDOM}"
    if ! "$cli" --socket "$socket" send "$pid" --text "$text" --context "$context" \
        --idempotency-key "$key" --capability-ticket "$ticket" --retries 2 >/dev/null 2>&1; then
      echo "agent> <send failed>" >&2
      continue
    fi
    if [ -n "$after" ]; then
      response=$("$cli" --socket "$socket" wait --type message.received --after "$after" \
        --timeout-ms $((timeout_s * 1000)) --json 2>/dev/null || true)
    else
      response=$("$cli" --socket "$socket" wait --type message.received \
        --timeout-ms $((timeout_s * 1000)) --json 2>/dev/null || true)
    fi
    printf '%s' "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('result') or {}
evs = r.get('events') or ([r.get('event')] if r.get('event') else [])
e = evs[0] if evs else {}
print('agent> ' + str((e.get('data') or {}).get('text') or '<no reply>'))
print('after=' + str(e.get('cursor') or ''))
" > "$work/reply.txt" 2>/dev/null || echo "agent> <no reply>" > "$work/reply.txt"
    grep -v '^after=' "$work/reply.txt"
    after=$(sed -n 's/^after=//p' "$work/reply.txt")
  done <<TURNS
$turns
TURNS

  if [ "$keep" = 1 ]; then
    echo "instance home: $home (socket $socket)"
    trap - EXIT INT TERM
    return 0
  fi

  trap - EXIT INT TERM
  kill "$serve_pid" "$daemon_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$work"
}

printf '%s\n' "$configs_trimmed" | while IFS= read -r config; do
  [ -n "$config" ] || continue
  run_config "$config"
done
