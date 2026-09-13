#!/bin/sh
set -eu

# M3 acceptance: contact ticket + cached discovery.
#
# An agent mints a contact ticket (transport + peer + a probed
# server/discover cache). A daemon adds the peer from the ticket with no live
# connection, then later dials it and runs server/discover for real — the
# cached copy is only a hint, and serverInfo is unverified display data.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p idfond -p idfon-cli -p idfon-mcp
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond

work=$(mktemp -d /tmp/idfon-mcp-ticket.XXXXXX)
pids=""
cleanup() {
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    wait $pids 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

NUF="$root/target/release/idfon"
printf '%064d' 3 > "$work/agent.key"
A="$work/a.sock"
Q() { "$NUF" --socket "$A" "${@:2}"; }

# Agent side: mint the contact ticket (probes its own server/discover).
"$root/target/release/idfon-mcp" serve \
  --contact \
  --key-file "$work/agent.key" \
  --mcp-command "python3 $root/scripts/mcp-fixture.py server" \
  >"$work/agent.out" 2>"$work/agent.err" &
pids="$pids $!"

TICKET=""
for _ in $(seq 1 100); do
  if [ -s "$work/agent.out" ]; then TICKET=$(head -n 1 "$work/agent.out"); break; fi
  sleep 0.1
done
if [ -z "$TICKET" ]; then
  echo "FAIL: agent printed no contact ticket" >&2
  cat "$work/agent.err" >&2
  exit 1
fi

# The ticket carries the cached discovery (transport + peer + discover).
if ! echo "$TICKET" | jq -e '.transport and .peer.endpoint_id and (.discover.supportedVersions | index("2026-07-28"))' >/dev/null; then
  echo "FAIL: contact ticket missing transport/peer/discover" >&2
  echo "$TICKET" >&2
  exit 1
fi
AGENT_EP=$(echo "$TICKET" | jq -r .peer.endpoint_id)

# Offline add: the daemon has never connected to the agent.
"$root/target/release/idfond" --socket "$A" --data-dir "$work/a" >"$work/a.log" 2>&1 &
pids="$pids $!"
for _ in $(seq 1 150); do
  "$NUF" --socket "$A" status --json >/dev/null 2>&1 && break
  sleep 0.1
done

Q "$A" peer add --mcp-ticket "$TICKET" --json >/dev/null
S=$(Q "$A" peer show "$AGENT_EP" --json)
if echo "$S" | jq -e '.result.peer.endpoint_id == "'"$AGENT_EP"'" and (.result.mcp_discovery.supportedVersions | index("2026-07-28")) and .result.mcp_discovery.serverInfo.name' >/dev/null; then
  echo "PASS: peer added from ticket offline, with cached server/discover"
else
  echo "FAIL: offline peer add did not cache discovery" >&2
  echo "$S" >&2
  exit 1
fi

Q "$A" access allow --subject "$AGENT_EP" --capability mcp.transport --json >/dev/null
SOCK=$(Q "$A" mcp listen --to "$AGENT_EP" --json | jq -r .result.socket)
if [ -z "$SOCK" ] || [ "$SOCK" = "null" ]; then
  echo "FAIL: mcp.listen returned no socket" >&2
  exit 1
fi

if ! python3 "$root/scripts/mcp-fixture.py" drive-uds "$root/target/release/idfon-mcp" "$SOCK"; then
  echo "FAIL: live server/discover through the relay" >&2
  echo "--- agent ---" >&2; tail -10 "$work/agent.err" >&2
  echo "--- daemon ---" >&2; tail -10 "$work/a.log" >&2
  exit 1
fi

echo "PASS: contact ticket added offline, then live server/discover succeeded"
