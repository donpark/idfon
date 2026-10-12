#!/bin/sh
# Headless voice-agent prompt lab with scoring.
#
# Brings up the real stack in a throwaway instance — a temp daemon, the holder
# (with a chosen live config), the eve agent, and the bridge — then sends
# scripted caller turns and prints the replies. No iPhone, no call, no audio.
# This exercises the holder -> agent path and the prompt surfaces
# (`live.json`'s `instructions`, the agent's `instructions.md`), so prompt
# changes iterate in seconds.
#
# Scoring: a turn can carry an expectation. A turn passes when the reply
# contains `expect` and contains none of `forbid`. A scored config prints
# `passed/scored` and a mean; several configs print a ranked table. Unscored
# turns are printed but do not affect the mean.
#
#   scripts/voice-prompt-lab.sh --turn "what is the capital of France?"
#   scripts/voice-prompt-lab.sh --turns turns.jsonl --score
#   scripts/voice-prompt-lab.sh --variants prompts/voices --turns turns.jsonl
#
#   --turn TEXT        one plain (unscored) caller turn (repeatable)
#   --turns FILE       turns, one per line: plain text, or a JSON object
#                      {"text": "...", "expect": "...", "forbid": ["..."]}
#                      ('#' comments ignored)
#   --config FILE      live config to serve (repeatable; default
#                      agents/<agent>/live.json)
#   --variants DIR     run every *.json in DIR as a config and rank them
#   --agent NAME       agent under agents/ (default llm)
#   --model ID         model id (default $EVE_IDFON_MODEL)
#   --context TEXT     per-turn caller context (default the app's client-cascade line)
#   --timeout SECS     per-reply timeout (default 120)
#   --score            print the per-config score line and the ranked table
#   --json-out FILE    append one JSON object per scored turn (machine-readable:
#                      config, text, reply, expect, forbid, score) for a scorer
#                      or optimizer on top (scripts/voice-gepa.sh)
#   --keep             leave the last stack running and print its home
#
# Requires AI_GATEWAY_API_KEY in the environment (the agent's model gateway).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

agent=llm
configs=""
variants=""
turns=""
model="${EVE_IDFON_MODEL:-}"
context="Client cascade (on-device speech). Recognition: Apple Built-in; Generation: Apple Built-in. The holder only produces text."
timeout_s=120
keep=0
score=0
json_out=""

usage() { sed -n '2,36p' "$0"; }

add_turn() {
  turns="$turns$1
"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --turn) add_turn "$2"; shift 2 ;;
    --turns) while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        add_turn "$line"
      done < "$2"; shift 2 ;;
    --config) configs="$configs$2
"; shift 2 ;;
    --variants) variants="$2"; shift 2 ;;
    --agent) agent="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --context) context="$2"; shift 2 ;;
    --timeout) timeout_s="$2"; shift 2 ;;
    --score) score=1; shift ;;
    --json-out) json_out="$2"; shift 2 ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$turns" ]; then
  echo "no turns: pass --turn TEXT or --turns FILE" >&2
  exit 2
fi

if [ -n "$variants" ]; then
  [ -d "$variants" ] || { echo "no such variants dir: $variants" >&2; exit 2; }
  for f in "$variants"/*.json; do
    [ -e "$f" ] || continue
    configs="$configs$f
"
  done
fi

cli="$root/target/release/idfon"
serve="$root/scripts/live-voice-serve.sh"
results="$(mktemp /tmp/idfon-lab-scores.XXXXXX)"

work=""
serve_pid=""
daemon_pid=""
cleanup() {
  [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null || true
  [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  [ "$keep" = 1 ] || [ -z "$work" ] || rm -rf "$work"
  serve_pid=""; daemon_pid=""
}
trap cleanup EXIT INT TERM

# Run one config and append "mean<TAB>passed<TAB>scored<TAB>config" to $results.
# Unscored turns record an empty mean.
run_config() {
  config=$1
  work=$(mktemp -d /tmp/idfon-voice-lab.XXXXXX)
  socket="$work/idfond.sock"
  home="$work/home"
  mkdir -p "$work/daemon" "$home"

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

  ready=0
  for _ in $(seq 1 600); do
    if [ -s "$home/holder.ticket" ] && [ -s "$home/capability-ticket.json" ]; then
      ready=1; break
    fi
    if ! kill -0 "$serve_pid" 2>/dev/null; then
      echo "serve failed; log:" >&2; tail -20 "$work/serve.log" >&2; exit 1
    fi
    sleep 0.1
  done
  [ "$ready" = 1 ] || { echo "serve did not become ready; log:" >&2; tail -20 "$work/serve.log" >&2; exit 1; }

  pid=$(head -1 "$home/holder.ticket" | jq -r .id)
  addr=$(head -1 "$home/holder.ticket")
  ticket=$(cat "$home/capability-ticket.json")
  "$cli" --socket "$socket" peer add "$pid" --name "lab" --endpoint-id "$pid" \
    --endpoint-addr "$addr" --json >/dev/null 2>&1 || true
  "$cli" --socket "$socket" access allow --subject "$pid" --capability message.send \
    --json >/dev/null 2>&1 || true

  echo "=== config: $config (agent $agent, model ${model:-default}) ==="
  after=""
  cfg_scored=0
  cfg_passed=0
  # A here-doc (not a pipe) so `after` and the counters survive across turns.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      \{*)
        text=$(printf '%s' "$line" | jq -r '.text // empty')
        expect=$(printf '%s' "$line" | jq -r '.expect // empty')
        forbid=$(printf '%s' "$line" | jq -r '(.forbid // [])[]' 2>/dev/null || true)
        ;;
      *) text="$line"; expect=""; forbid="" ;;
    esac
    [ -n "$text" ] || continue

    echo "caller> $text"
    key="lab-$(date +%s)-${RANDOM}"
    reply="<send failed>"
    if "$cli" --socket "$socket" send "$pid" --text "$text" --context "$context" \
        --idempotency-key "$key" --capability-ticket "$ticket" --retries 2 >/dev/null 2>&1; then
      if [ -n "$after" ]; then
        response=$("$cli" --socket "$socket" wait --type message.received --after "$after" \
          --timeout-ms $((timeout_s * 1000)) --json 2>/dev/null || true)
      else
        response=$("$cli" --socket "$socket" wait --type message.received \
          --timeout-ms $((timeout_s * 1000)) --json 2>/dev/null || true)
      fi
      reply=$(printf '%s' "$response" | jq -r \
        '(.result.events[0] // .result.event // {}).data.text // "<no reply>"' 2>/dev/null || true)
      after=$(printf '%s' "$response" | jq -r \
        '(.result.events[0] // .result.event // {}).cursor // empty' 2>/dev/null || true)
      [ -n "$reply" ] || reply="<no reply>"
    fi

    # Score only when the turn carries an expectation.
    if [ -n "$expect" ] || [ -n "$forbid" ]; then
      cfg_scored=$((cfg_scored + 1))
      turn_score=1
      if [ -n "$expect" ] && ! printf '%s' "$reply" | grep -qiF -- "$expect"; then
        turn_score=0
      fi
      if [ -n "$forbid" ]; then
        # A hit exits 7; a clean run must end status 0, so use `if`. A
        # trailing `grep && exit` would leak grep's non-match status (1).
        # `printf '%s\n'`: a list built with $(...) has no trailing newline, and
        # `while read` skips a final line without one — so the last forbid
        # entry used to be silently never tested.
        printf '%s\n' "$forbid" | while IFS= read -r bad; do
          [ -n "$bad" ] || continue
          if printf '%s' "$reply" | grep -qiF -- "$bad"; then exit 7; fi
        done && : || turn_score=0
      fi
      cfg_passed=$((cfg_passed + turn_score))
      echo "agent> $reply  [score=$turn_score]"
      if [ -n "$json_out" ]; then
        jq -cn --arg config "$config" --arg text "$text" --arg reply "$reply" \
          --arg expect "$expect" --arg forbid "$forbid" --argjson score "$turn_score" \
          '{config: $config, text: $text, reply: $reply, expect: $expect,
            forbid: ($forbid | split("\n") | map(select(length > 0))), score: $score}' \
          >>"$json_out"
      fi
    else
      echo "agent> $reply"
    fi
  done <<TURNS
$turns
TURNS

  if [ "$cfg_scored" -gt 0 ]; then
    mean=$(awk "BEGIN{printf \"%.3f\", $cfg_passed/$cfg_scored}")
    printf '%s\t%s\t%s\t%s\n' "$mean" "$cfg_passed" "$cfg_scored" "$config" >>"$results"
    [ "$score" = 1 ] && echo "score: $cfg_passed/$cfg_scored = $mean"
  else
    printf '\t\t\t%s\n' "$config" >>"$results"
  fi

  trap - EXIT INT TERM
  kill "$serve_pid" "$daemon_pid" 2>/dev/null || true
  serve_pid=""; daemon_pid=""
  wait 2>/dev/null || true
  [ "$keep" = 1 ] || rm -rf "$work"
  work=""
  trap cleanup EXIT INT TERM
}

printf '%s' "$configs" | sed '/^$/d' >"$results.configs"
config_count=$(wc -l <"$results.configs" | tr -d ' ')
if [ "$config_count" = 0 ]; then
  echo "agents/$agent/live.json" >"$results.configs"
  config_count=1
fi
while IFS= read -r config; do
  [ -n "$config" ] || continue
  run_config "$config"
done <"$results.configs"

if [ "$config_count" -gt 1 ]; then
  echo
  echo "=== ranked ==="
  sort -t"$(printf '\t')" -k1,1r "$results" | awk -F'\t' '
    BEGIN { printf "%-7s %-8s %-10s %s\n", "rank", "mean", "passed", "config" }
    { printf "%-7d %-8s %-10s %s\n", NR, ($1 == "" ? "-" : $1), $2 "/" $3, $4 }'
fi

rm -f "$results" "$results.configs"
trap cleanup EXIT INT TERM
