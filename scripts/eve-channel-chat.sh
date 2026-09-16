#!/bin/sh
# Chat with an Eve agent over idfon.
#
# The agent is reached over the ordinary peer path — `peer add`, `access
# allow`, `send` — exactly as a human peer would be. idfon has no agent-only
# verbs; the holder's capability ticket is the *agent's own* ingress policy,
# not a distinction the client makes.
#
#   scripts/eve-channel-chat.sh --prompt "hello"                # one turn
#   scripts/eve-channel-chat.sh --prompt "hi" --prompt "again"  # several turns
#   scripts/eve-channel-chat.sh                                 # type turns, Ctrl-D to quit
#
#   --prompt TEXT   send one turn and print the reply (repeatable; omitting
#                   it starts an interactive session)
#   --model ID      AI Gateway model id (default $IDFON_EVE_MODEL, else
#                   anthropic/claude-haiku-4.5)
#   --agent-dir DIR Eve app to run (default scripts/eve-channel-app)
#   --timeout SECS  wait per reply (default 120)
#   --no-build      reuse already-built binaries
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

model="${IDFON_EVE_MODEL:-anthropic/claude-haiku-4.5}"
agent_src="$root/scripts/eve-channel-app"
timeout_s=120
build=1
prompts=""

usage() { sed -n '2,22p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt) prompts="$prompts$2
"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --agent-dir) agent_src="$2"; shift 2 ;;
    --timeout) timeout_s="$2"; shift 2 ;;
    --no-build) build=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# agent.ts reads this at runtime.
export IDFON_EVE_MODEL="$model"

integration="$root/integrations/eve-idfon-channel"
if [ "$build" = 1 ]; then
  (
    cd "$integration"
    npm install --no-audit --no-fund --silent
    npm run build >/dev/null
  )
  RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
    cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
  cargo build --release -p idfond -p idfon-cli -p idfon-eve-channel
  codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond
fi

work=$(mktemp -d /tmp/idfon-eve-chat.XXXXXX)
pids=""
cleanup() {
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  [ -n "$pids" ] && wait $pids 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

NUF="$root/target/release/idfon"
HOLDER="$root/target/release/idfon-eve-channel"
A="$work/a/idfond.sock"
HOLDER_SOCK="$work/holder.sock"
mkdir -p "$work/a"
printf '%064d' 17 > "$work/holder.key"

free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}

# --- the human's client daemon -------------------------------------------
"$root/target/release/idfond" --socket "$A" --data-dir "$work/a" >"$work/a.log" 2>&1 &
pids="$pids $!"
for _ in $(seq 1 150); do
  if "$NUF" --socket "$A" status --json >/dev/null 2>&1; then break; fi
  sleep 0.1
done
A_PID=$("$NUF" --socket "$A" status --json | jq -r .result.identity.public_key)
HOLDER_TICKET=$("$HOLDER" --key-file "$work/holder.key" ticket --subject "$A_PID")

# --- the agent's endpoint holder -----------------------------------------
"$HOLDER" --key-file "$work/holder.key" serve --socket "$HOLDER_SOCK" --allow "$A_PID" \
  >"$work/holder.ticket" 2>"$work/holder.log" &
pids="$pids $!"
for _ in $(seq 1 150); do
  if [ -s "$work/holder.ticket" ]; then break; fi
  sleep 0.1
done
HOLDER_ADDR=$(head -n 1 "$work/holder.ticket")
HOLDER_PID=$(printf '%s' "$HOLDER_ADDR" | jq -r .id)

# --- the Eve app + its channel bridge ------------------------------------
app="$work/app"
mkdir -p "$app"
cp -R "$agent_src/." "$app/"
cat > "$app/package.json" <<EOF
{
  "name": "idfon-eve-chat",
  "private": true,
  "type": "module",
  "dependencies": {
    "eve": "0.55.0",
    "idfon-eve-channel": "file:$integration"
  }
}
EOF
bridge_port=$(free_port)
eve_port=$(free_port)
sed -i '' "s/18766/$bridge_port/" "$app/agent/extensions/idfon.ts"
(
  cd "$app"
  npm install --no-audit --no-fund --silent
  npx eve build >"$work/eve-build.log" 2>&1
  npx eve start --host 127.0.0.1 --port "$eve_port" >"$work/eve.log" 2>&1
) &
pids="$pids $!"
for _ in $(seq 1 300); do
  if curl -sS -o /dev/null "http://127.0.0.1:$eve_port/idfon/turn" 2>/dev/null; then break; fi
  sleep 0.1
done

node "$integration/bridge.mjs" --socket "$HOLDER_SOCK" \
  --target "http://127.0.0.1:$eve_port" --secret m2-test-secret --port "$bridge_port" \
  >"$work/bridge.out" 2>"$work/bridge.log" &
pids="$pids $!"
for _ in $(seq 1 150); do
  if curl -fsS "http://127.0.0.1:$bridge_port/health" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

# --- pair with the agent exactly like any other peer ----------------------
"$NUF" --socket "$A" peer add "$HOLDER_PID" --name eve \
  --endpoint-id "$HOLDER_PID" --endpoint-addr "$HOLDER_ADDR" --json >/dev/null
"$NUF" --socket "$A" access allow --subject "$HOLDER_PID" \
  --capability message.send --json >/dev/null

after=""

send_turn() {
  key="chat-$(python3 -c 'import time;print(time.time_ns())')"
  if ! "$NUF" --socket "$A" send "$HOLDER_PID" --text "$1" \
      --idempotency-key "$key" --capability-ticket "$HOLDER_TICKET" --retries 2 >/dev/null; then
    echo "agent: <send failed>" >&2
    return 0
  fi
  # Advance past each reply: a wait with no `after` returns the same event
  # again, so a second turn would otherwise print the first reply.
  if [ -n "$after" ]; then
    response=$("$NUF" --socket "$A" wait --type message.received --after "$after" \
      --timeout-ms $((timeout_s * 1000)) --json 2>/dev/null || true)
  else
    response=$("$NUF" --socket "$A" wait --type message.received \
      --timeout-ms $((timeout_s * 1000)) --json 2>/dev/null || true)
  fi
  event=$(printf '%s' "$response" | jq -c '(.result.events[0] // .result.event // empty)' 2>/dev/null || true)
  reply=$(printf '%s' "$event" | jq -r '.data.text // empty' 2>/dev/null || true)
  after=$(printf '%s' "$event" | jq -r '.cursor // empty' 2>/dev/null || true)
  if [ -n "$reply" ]; then
    printf 'agent> %s\n' "$reply"
  else
    printf 'agent> <no reply within %ss>\n' "$timeout_s" >&2
  fi
}

printf 'model %s\npeer %s\n\n' "$model" "$HOLDER_PID"

if [ -n "$prompts" ]; then
  printf '%s' "$prompts" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'you> %s\n' "$line"
    send_turn "$line"
  done
else
  printf 'Ctrl-D to quit.\n'
  while printf 'you> '; IFS= read -r line; do
    [ -n "$line" ] || continue
    send_turn "$line"
  done
  printf '\n'
fi