#!/bin/bash
# Serve the live-voice agent (Eve app + idfon channel holder + bridge) as a
# long-lived local service against the real daemon, and print what the Apple
# apps need to pair with it.
#
#   scripts/live-voice-serve.sh                  # foreground
#   scripts/live-voice-serve.sh &                # background
#
# Requires the daemon on --socket (default /tmp/idfon/idfond.sock) and
# AI_GATEWAY_API_KEY (GPT-Live voice sessions + gpt-6-luna delegation).
#
# GPT-Live is one voice backend (full-duplex model). This script serves a
# voice agent; set EVE_IDFON_BIN/EVE_IDFON_PKG to run a different backend
# runner (e.g. eve-idfon-voice for the cascade). See docs/voice-agent.md.
# Optional: EVE_IDFON_MODEL (orchestrator; default openai/gpt-6-luna).
#
# Prints, then stays in the foreground:
#   contact:  <endpoint-addr JSON>          -> `pnpm pair --eve-ticket <json>`
#   ticket:   <capability-ticket JSON>      -> mac `-pair-ticket eve <json>`,
#                                              iOS `-pair-ticket eve <json>`
#
# The holder key persists per instance at
# ${EVE_VOICE_HOME:-$HOME/.idfon/$EVE_INSTANCE} so each contact keeps one
# identity across restarts — pair once. EVE_INSTANCE (default: the agent
# name) keys the identity/home/port, so several contacts can run the same
# agent with different EVE_IDFON_MODEL and separate identities. EVE_CONTACT_NAME
# (default: the instance) is the display name printed in the pairing command;
# the app may still rename the contact locally.

set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli="${IDFON_CLI:-$root/target/release/idfon}"
socket="${IDFON_SOCKET:-/tmp/idfon/idfond.sock}"
agent="${EVE_AGENT:-live-voice}"
# EVE_INSTANCE keys the contact's identity/home/ports. `auto` derives a slug
# from the contact/model so contacts get stable, readable instance names
# instead of ad-hoc ones; unset keeps the agent name.
instance="${EVE_INSTANCE:-$agent}"
if [ "$instance" = auto ]; then
  slug_source="${EVE_CONTACT_NAME:-${EVE_IDFON_MODEL:-$agent}}"
  instance=$(printf '%s' "$slug_source" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [ -n "$instance" ] || instance="$agent"
fi
contact_name="${EVE_CONTACT_NAME:-$instance}"
home="${EVE_VOICE_HOME:-$HOME/.idfon/$instance}"
mkdir -p "$home"
# Pin the holder's UDP port so its endpoint address survives restarts and the
# apps do not need re-pairing. Deterministic per agent, persisted, overridable.
port_file="$home/endpoint-port"
if [ -n "${EVE_VOICE_PORT:-}" ]; then
  endpoint_port="$EVE_VOICE_PORT"
elif [ -s "$port_file" ]; then
  endpoint_port=$(cat "$port_file")
else
  endpoint_port=$((58000 + $(printf '%s' "$instance" | cksum | awk '{print $1}') % 1000))
fi
printf '%s' "$endpoint_port" > "$port_file" 2>/dev/null || true
integration="$root/integrations/eve-idfon"

# Holder runner. Default is the voice-agent runner carrying the full-duplex
# GPT-Live backend; `live.json` selects the backend (`gpt-live`, `cascade`,
# `relay`). The cascade demo uses the same binary with a different config.
holder_pkg="${EVE_IDFON_PKG:-idfon-voice-agent}"
holder_bin="${EVE_IDFON_BIN:-eve-idfon-voice}"
# Cargo features for the holder package. `gpt-live` links the OpenAI Live-API
# backend; set empty for a cascade/relay-only build.
holder_features="${EVE_IDFON_FEATURES:-gpt-live}"

: "${AI_GATEWAY_API_KEY:?AI_GATEWAY_API_KEY must be set}"
model="${EVE_IDFON_MODEL:-openai/gpt-6-luna}"
export EVE_IDFON_MODEL="$model"

mkdir -p "$home"
key="$home/holder.key"
if [ ! -s "$key" ]; then printf '%064d' "$((RANDOM * RANDOM))" > "$key"; fi

# Build when the holder is missing or any Rust source it is built from is
# newer. Existence alone is not enough: a stale binary silently outlives a
# source change (e.g. the voice-route gate), so check mtimes too.
holder_bin_path="$root/target/release/$holder_bin"
stale=0
if [ ! -x "$holder_bin_path" ]; then
  stale=1
elif [ -n "$(
  find "$root/crates" "$root/native/vendor/iroh-c-ffi/src" \
    "$root/Cargo.toml" "$root/Cargo.lock" \
    "$root/native/vendor/iroh-c-ffi/Cargo.toml" \
    -newer "$holder_bin_path" -print -quit 2>/dev/null
)" ]; then
  stale=1
fi
if [ "$stale" = 1 ] || [ "${FORCE_BUILD:-}" = 1 ]; then
  RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
    cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
  cargo build --release -p idfond -p idfon-cli
  cargo build --release -p "$holder_pkg" ${holder_features:+--features "$holder_features"}
  codesign --force -s - "$root/target/release/libiroh_c_ffi.dylib" \
    "$root/target/release/$holder_bin" "$root/target/release/idfond"
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
   [ "$root/agents/$agent/package.json" -nt "$app/.output" ] || \
   [ -n "$(find "$root/agents/$agent/agent" -newer "$app/.output" -print -quit 2>/dev/null)" ]; then
  rm -rf "$app"
  mkdir -p "$app"
  cp -R "$root/agents/$agent/agent" "$root/agents/$agent/package.json" \
    "$root/agents/$agent/package-lock.json" "$app/"
  cp -R "$root/agents/$agent/node_modules" "$app/node_modules"
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

# Every sender the agent should accept: the daemon itself, every daemon peer,
# and every endpoint we have already minted a subject-bound ticket for. The
# ticket files keep devices reachable across a daemon state reset, which
# empties peer list while the devices still hold their tickets. Each sender
# also needs its own ticket, minted further down.
extra_senders() {
  "$cli" --socket "$socket" peer list --json \
    | jq -r '.result.peers[]? | (.endpoint_id // .id) | select(. != null)' 2>/dev/null
  for f in "$home"/capability-ticket-*.json; do
    [ -e "$f" ] || continue
    basename "$f" .json | sed 's/^capability-ticket-//'
  done
}
allow_args=(--allow "$daemon_id")
while IFS= read -r endpoint; do
  [ -n "$endpoint" ] && [ "$endpoint" != "$daemon_id" ] && allow_args+=(--allow "$endpoint")
done < <(extra_senders | awk '!seen[$0]++')

# Stop anything from a previous run of THIS script.
for pidfile in "$home"/holder.pid "$home"/bridge.pid "$home"/eve.pid; do
  if [ -f "$pidfile" ]; then kill "$(cat "$pidfile")" 2>/dev/null || true; rm -f "$pidfile"; fi
done
sleep 0.5
# Senders admitted after startup (e.g. an agency invite) are appended here by
# the provisioner; the holder reloads the file while running.
touch "$home/allowed-peers"
live_args=()
# Live config: the agent's own, or an override for a provider tryout
# (scripts/voice-agent-serve.sh passes EVE_LIVE_CONFIG).
live_config_path="${EVE_LIVE_CONFIG:-$root/agents/$agent/live.json}"
if [ -f "$live_config_path" ]; then
  live_args=(--live-config "$live_config_path")
fi

# Reply credential: to answer the agency's A2A intro the holder must present a
# ticket the agency issued for US (subject = our holder endpoint id). Fetch it
# before the holder starts so it can be loaded with --reply-ticket-file; the
# agency also admits us as a sender when it mints. Our endpoint id is derived
# from the key, so this does not need the holder running.
reply_args=()
if [ -n "${AGENCY_URL:-}" ]; then
  self_id=$("$root/target/release/$holder_bin" --key-file "$key" ticket --subject self 2>/dev/null | jq -r .issuer)
  if [ -n "$self_id" ] && [ "$self_id" != null ]; then
    if reply_ticket=$(curl -fsS -X POST "$AGENCY_URL/reply-ticket" \
        -H 'content-type: application/json' \
        -H "x-idfon-provisioner-secret: ${AGENCY_PROVISIONER_SECRET:-m2-test-secret}" \
        -d "{\"peer_id\":\"$self_id\"}"); then
      printf '%s' "$reply_ticket" > "$home/reply-ticket.json"
      reply_args=(--reply-ticket-file "$home/reply-ticket.json")
    else
      echo "reply ticket fetch failed; A2A replies to the agency will be denied" >&2
    fi
  fi
fi
IDFON_ENDPOINT_PORT="$endpoint_port" "$root/target/release/$holder_bin" --key-file "$key" serve \
  --socket "$home/holder.sock" "${allow_args[@]}" --allow-file "$home/allowed-peers" \
  --blob-dir "$home/blobs" \
  ${live_args[@]+"${live_args[@]}"} \
  ${reply_args[@]+"${reply_args[@]}"} \
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

# Agent tools reach their own bridge (for A2A card requests) via these.
export IDFON_BRIDGE_URL="http://127.0.0.1:$bridge_port"
# Persist the bridge URL so a companion process (e.g. the standalone live
# relay) can find it without re-deriving the port.
printf '%s' "$IDFON_BRIDGE_URL" > "$home/bridge-url" 2>/dev/null || true
export IDFON_BRIDGE_SECRET=m2-test-secret

# Optional self-registration: when AGENCY_URL is set, this agent issues a
# card bound to the agency (subject = agency peer id) with its OWN holder
# and registers it. The agency signs nothing and never reads our key.
if [ -n "${AGENCY_URL:-}" ]; then
  dir_peer="${AGENCY_PEER:-}"
  if [ -z "$dir_peer" ] && [ -s "$HOME/.idfon/agency/holder.ticket" ]; then
    dir_peer=$(head -1 "$HOME/.idfon/agency/holder.ticket" | jq -r .id)
  fi
  if [ -n "$dir_peer" ]; then
    grep -qxF "$dir_peer" "$home/allowed-peers" 2>/dev/null || printf '%s\n' "$dir_peer" >> "$home/allowed-peers"
    card=$(curl -fsS -X POST "http://127.0.0.1:$bridge_port/card" \
      -H 'content-type: application/json' -H 'x-idfon-channel-secret: m2-test-secret' \
      -d "{\"subject\":\"$dir_peer\",\"capabilities\":[\"agent.receive\"]}") || card=''
    if [ -n "$card" ]; then
      body=$(jq -nc --arg name "$contact_name" --arg model "$model" \
        --argjson addr "$(printf '%s' "$card" | jq -c '.endpoint_addr')" \
        --argjson ticket "$(printf '%s' "$card" | jq -c '.ticket')" \
        '{name:$name, model:$model, endpoint_addr:$addr, capability_ticket:$ticket}')
      curl -fsS -X POST "$AGENCY_URL/register" -H 'content-type: application/json' \
        -H "x-idfon-provisioner-secret: ${AGENCY_PROVISIONER_SECRET:-m2-test-secret}" -d "$body" \
        && echo "registered $model with agency ($AGENCY_URL)" \
        || echo "agency registration failed" >&2
    else
      echo "agency registration failed: no card from holder" >&2
    fi
  fi
fi
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
"$root/target/release/$holder_bin" --key-file "$key" ${live_args[@]+"${live_args[@]}"} ticket \
  --subject "$daemon_id" > "$home/capability-ticket.json"
while IFS= read -r endpoint; do
  "$root/target/release/$holder_bin" --key-file "$key" ${live_args[@]+"${live_args[@]}"} ticket \
    --subject "$endpoint" > "$home/capability-ticket-$endpoint.json"
done < <(extra_senders | awk '!seen[$0]++')

contact=$(head -n 1 "$home/holder.ticket")
holder_pid=$(printf '%s' "$contact" | jq -r .id)

# Grants on the DAEMON side: the apps' sends carry the holder's capability
# ticket; the holder's replies need message.receive/send grants keyed by the
# holder's endpoint id (not the peer display name — grant subjects are
# matched against peer.id, and channel peers must have id == endpoint id).
"$cli" --socket "$socket" access allow --subject "$holder_pid" --capability message.send >/dev/null
"$cli" --socket "$socket" access allow --subject "$holder_pid" --capability message.receive >/dev/null
{
  echo "$agent agent is up (holder $holder_pid, endpoint udp :$endpoint_port, bridge :$bridge_port, eve :$eve_port)"
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
  echo "  idfon --socket $socket peer add $holder_pid --name \"$contact_name\" --endpoint-id $holder_pid --endpoint-addr \"\$(head -1 $home/holder.ticket)\""}
  echo "  pnpm pair --eve-ticket \"\$(head -1 $home/holder.ticket)\""
  echo "  open Idfon.app with: -pair-ticket $holder_pid \"\$(cat $home/capability-ticket.json)\""
  echo "  (iOS: devicectl launch ... -- -pair-ticket $holder_pid \"\$(cat $home/capability-ticket-<ios-endpoint-id>.json)\")"
} | tee "$home/pairing.txt"

trap 'kill "$(cat "$home/holder.pid" 2>/dev/null)" "$(cat "$home/bridge.pid" 2>/dev/null)" "$(cat "$home/eve.pid" 2>/dev/null)" 2>/dev/null || true' EXIT
echo
echo "serving; Ctrl-C to stop"
wait
