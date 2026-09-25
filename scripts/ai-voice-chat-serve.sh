#!/bin/bash
# Serve the ai-voice-chat agent (Eve app + idfon channel holder + bridge) as a
# long-lived local service against the real daemon, and print what the Apple
# apps need to pair with it.
#
#   scripts/ai-voice-chat-serve.sh                  # foreground
#   scripts/ai-voice-chat-serve.sh &                # background
#
# Requires the daemon on --socket (default /tmp/idfon/idfond.sock) and
# AI_GATEWAY_API_KEY (GPT-Live voice sessions + gpt-6-luna delegation).
# Optional: EVE_IDFON_MODEL (orchestrator; default openai/gpt-6-luna).
#
# Prints, then stays in the foreground:
#   contact:  <endpoint-addr JSON>          -> `pnpm pair --eve-ticket <json>`
#   ticket:   <capability-ticket JSON>      -> mac `-pair-ticket eve <json>`,
#                                              iOS `-pair-ticket eve <json>`
#
# The holder key persists at ${EVE_VOICE_HOME:-$HOME/.idfon/ai-voice-chat} so
# the agent keeps one identity across restarts — pair once.

set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli="${IDFON_CLI:-$root/target/release/idfon}"
socket="${IDFON_SOCKET:-/tmp/idfon/idfond.sock}"
home="${EVE_VOICE_HOME:-$HOME/.idfon/ai-voice-chat}"
integration="$root/integrations/eve-idfon"

: "${AI_GATEWAY_API_KEY:?AI_GATEWAY_API_KEY must be set}"
model="${EVE_IDFON_MODEL:-openai/gpt-6-luna}"
export EVE_IDFON_MODEL="$model"

mkdir -p "$home"
key="$home/holder.key"
if [ ! -s "$key" ]; then printf '%064d' "$((RANDOM * RANDOM))" > "$key"; fi

# Build once; skip when binaries and the compiled app are current.
if [ ! -x "$root/target/release/eve-idfon" ] || [ "${FORCE_BUILD:-}" = 1 ]; then
  RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
    cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
  cargo build --release -p idfond -p idfon-cli -p eve-idfon
  codesign --force -s - "$root/target/release/libiroh_c_ffi.dylib" \
    "$root/target/release/eve-idfon" "$root/target/release/idfond"
fi

app="$home/app"
# Pick the bridge port first: the app's channel wiring must carry it into the
# build (the compiled .output bakes the URL in).
bridge_port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])
PY
)
eve_port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])
PY
)
# Reuse the previous bridge port when possible: the compiled .output bakes it
# in, so a changed port means a full eve rebuild. Keep the port stable across
# restarts (it is only a loopback port).
if [ -d "$app/.output" ] && grep -q "bridgeUrl: \"http://127.0.0.1:[0-9]*\"" "$app/agent/extensions/idfon.ts" 2>/dev/null; then
  prev_bridge=$(sed -n 's|.*bridgeUrl: "http://127.0.0.1:\([0-9]*\)".*|\1|p' "$app/agent/extensions/idfon.ts")
  if [ -n "$prev_bridge" ] && ! lsof -nP -iTCP:"$prev_bridge" -sTCP:LISTEN >/dev/null 2>&1; then
    bridge_port=$prev_bridge
  fi
fi
if [ ! -d "$app/.output" ] || [ "${FORCE_BUILD:-}" = 1 ] || \
   [ "$root/agents/ai-voice-chat/agent/agent.ts" -nt "$app/.output" ]; then
  rm -rf "$app"
  mkdir -p "$app"
  cp -R "$root/agents/ai-voice-chat/agent" "$root/agents/ai-voice-chat/package.json" \
    "$root/agents/ai-voice-chat/package-lock.json" "$app/"
  cp -R "$root/agents/ai-voice-chat/node_modules" "$app/node_modules"
  # eve-idfon is a relative symlink inside the agent's node_modules;
  # repoint it at the repo checkout.
  ln -sfn "$integration" "$app/node_modules/eve-idfon"
fi
# Patch the app's bridge wiring to the chosen port BEFORE building.
sed -i '' "s|bridgeUrl: \"http://127.0.0.1:[0-9]*\"|bridgeUrl: \"http://127.0.0.1:$bridge_port\"|" \
  "$app/agent/extensions/idfon.ts"
if [ ! -d "$app/.output" ]; then
  (cd "$app" && npx --offline eve build >"$home/eve-build.log" 2>&1)
fi

# Daemon identity = the holder's ticket subject and the peer the apps add.
daemon_id=$("$cli" --socket "$socket" status --json | jq -r '.result.identity.endpoint_id // .result.identity.public_key // .result.identity.id')
[ -n "$daemon_id" ] || { echo "cannot read daemon identity on $socket" >&2; exit 1; }

# Every daemon peer may talk to the agent, so allow-list them all: the daemon
# itself plus paired devices (iPhone etc.). Each sender also needs its own
# subject-bound capability ticket, minted further down.
allow_args=(--allow "$daemon_id")
while IFS=$'\t' read -r peer_name endpoint; do
  [ "$endpoint" = "$daemon_id" ] && continue
  allow_args+=(--allow "$endpoint")
done < <("$cli" --socket "$socket" peer list --json | jq -r '.result.peers[] | "\(.name)\t\(.endpoint_id // .id)"')

# Stop anything from a previous run of THIS script.
for pidfile in "$home"/holder.pid "$home"/bridge.pid "$home"/eve.pid; do
  if [ -f "$pidfile" ]; then kill "$(cat "$pidfile")" 2>/dev/null || true; rm -f "$pidfile"; fi
done
sleep 0.5
"$root/target/release/eve-idfon" --key-file "$key" serve \
  --socket "$home/holder.sock" "${allow_args[@]}" --blob-dir "$home/blobs" \
  >"$home/holder.ticket" 2>"$home/holder.log" &
echo $! > "$home/holder.pid"
for _ in $(seq 1 150); do [ -s "$home/holder.ticket" ] && break; sleep 0.1; done

node "$integration/bridge.mjs" --socket "$home/holder.sock" \
  --target "http://127.0.0.1:$eve_port" --secret m2-test-secret --port "$bridge_port" \
  >"$home/bridge.out" 2>"$home/bridge.log" &
echo $! > "$home/bridge.pid"
for _ in $(seq 1 150); do
  curl -fsS "http://127.0.0.1:$bridge_port/health" >/dev/null 2>&1 && break
  sleep 0.1
done

(cd "$app" && exec "$app/node_modules/.bin/eve" start --host 127.0.0.1 --port "$eve_port") \
  >"$home/eve.log" 2>&1 &
echo $! > "$home/eve.pid"
for _ in $(seq 1 200); do
  curl -sS -o /dev/null "http://127.0.0.1:$eve_port/idfon/turn" 2>/dev/null && break
  sleep 0.1
done

# Capability tickets: holder-signed, subject-bound to each sender (the holder
# rejects a ticket whose subject != the message's sender id), covering the
# message ingress the apps' sends need. One file per peer.
"$root/target/release/eve-idfon" --key-file "$key" ticket \
  --subject "$daemon_id" > "$home/capability-ticket.json"
while IFS=$'\t' read -r peer_name endpoint; do
  "$root/target/release/eve-idfon" --key-file "$key" ticket \
    --subject "$endpoint" > "$home/capability-ticket-$endpoint.json"
done < <("$cli" --socket "$socket" peer list --json | jq -r '.result.peers[] | "\(.name)\t\(.endpoint_id // .id)"' | awk -F'\t' '$2 != "" && $2 != "'"$daemon_id"'"')

contact=$(head -n 1 "$home/holder.ticket")
holder_pid=$(printf '%s' "$contact" | jq -r .id)

# Grants on the DAEMON side: the apps' sends carry the holder's capability
# ticket; the holder's replies need message.receive/send grants keyed by the
# holder's endpoint id (not the peer display name — grant subjects are
# matched against peer.id, and channel peers must have id == endpoint id).
"$cli" --socket "$socket" access allow --subject "$holder_pid" --capability message.send >/dev/null
"$cli" --socket "$socket" access allow --subject "$holder_pid" --capability message.receive >/dev/null
{
  echo "ai-voice-chat agent is up (holder $holder_pid, bridge :$bridge_port, eve :$eve_port)"
  echo
  echo "contact:  $contact"
  echo
  echo "ticket:   $(cat "$home/capability-ticket.json")   # subject: this daemon"
  for f in "$home"/capability-ticket-*.json; do
    [ -e "$f" ] || continue
    echo "ticket:   $(cat "$f")"
    echo "          ^ subject: peer $(basename "$f" .json | sed "s/capability-ticket-//")"
  done
  echo
  echo "pairing:"
  echo "  # the peer id MUST be the holder's endpoint id (channel peers need id == endpoint id)"
  echo "  # each app installs the ticket subject-bound to ITS OWN endpoint id"
  echo "  idfon --socket $socket peer add $holder_pid --name ai-voice-chat --endpoint-id $holder_pid --endpoint-addr \"\$(head -1 $home/holder.ticket)\""
  echo "  pnpm pair --eve-ticket \"\$(head -1 $home/holder.ticket)\""
  echo "  open Idfon.app with: -pair-ticket $holder_pid \"\$(cat $home/capability-ticket.json)\""
  echo "  (iOS: devicectl launch ... -- -pair-ticket $holder_pid \"\$(cat $home/capability-ticket-<ios-endpoint-id>.json)\")"
} | tee "$home/pairing.txt"

trap 'kill "$(cat "$home/holder.pid" 2>/dev/null)" "$(cat "$home/bridge.pid" 2>/dev/null)" "$(cat "$home/eve.pid" 2>/dev/null)" 2>/dev/null || true' EXIT
echo
echo "serving; Ctrl-C to stop"
wait
