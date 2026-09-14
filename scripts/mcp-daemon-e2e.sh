#!/bin/sh
set -eu

# M2 acceptance: the user-side daemon relay.
#
# Two daemons with real iroh transports carry a stock MCP stdio scenario:
#   A's `idfon mcp listen --to B` opens a local socket, `idfon-mcp connect
#   --uds` bridges stdio to it, A's daemon dials B on idfon/mcp/1, and B's
#   daemon splices the stream to IDFON_MCP_COMMAND. Both directions require an
#   `mcp.transport` grant; the daemon never parses MCP.
#
# PASS requires every check to pass; exits non-zero on the first failure.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# The thin idfond links the vendored dylib; a relink can leave a stale ad-hoc
# signature the kernel kills (same preamble as test-cli.sh).
RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p idfond -p idfon-cli -p idfon-mcp
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond

work=$(mktemp -d /tmp/idfon-mcp-daemon.XXXXXX)
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
A="$work/a/idfond.sock"
B="$work/b/idfond.sock"
Q() { "$NUF" --socket "$1" "${@:2}"; }

mkdir -p "$work/a" "$work/b"
"$NUF" --socket "$A" --data-dir "$work/a" >"$work/a.log" 2>&1 &
pids="$pids $!"
IDFON_MCP_COMMAND="python3 $root/scripts/mcp-fixture.py server" \
  "$root/target/release/idfond" --socket "$B" --data-dir "$work/b" >"$work/b.log" 2>&1 &
pids="$pids $!"

wait_ready() { # socket label
  for _ in $(seq 1 150); do
    if "$NUF" --socket "$1" status --json >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  echo "FAIL: daemon $2 not ready" >&2
  return 1
}
wait_ready "$A" A
wait_ready "$B" B

A_EP=$(Q "$A" status --json | jq -r .result.identity.endpoint_id)
A_PID=$(Q "$A" status --json | jq -r .result.identity.public_key)
A_ADDR=$(Q "$A" status --json | jq -r '.result.ticket | implode')
B_EP=$(Q "$B" status --json | jq -r .result.identity.endpoint_id)
B_PID=$(Q "$B" status --json | jq -r .result.identity.public_key)
B_ADDR=$(Q "$B" status --json | jq -r '.result.ticket | implode')

Q "$A" peer add "$B_PID" --name bob --endpoint-id "$B_EP" --endpoint-addr "$B_ADDR" --json >/dev/null
Q "$B" peer add "$A_PID" --name alice --endpoint-id "$A_EP" --endpoint-addr "$A_ADDR" --json >/dev/null

# peer.show surfaces grant state, and mcp.configure persists the relay command.
if Q "$A" peer show bob --json | jq -e '.ok and .result.mcp_transport_granted == false' >/dev/null; then
  echo "PASS: peer.show reports mcp.transport not granted"
else
  echo "FAIL: peer.show should report mcp_transport_granted=false" >&2
  exit 1
fi

CONFIG_CMD="python3 $root/scripts/mcp-fixture.py server"
if Q "$A" mcp configure --command "$CONFIG_CMD" --json | jq -e --arg c "$CONFIG_CMD" '.ok and .result.command == $c' >/dev/null; then
  echo "PASS: mcp.configure persisted the relay command"
else
  echo "FAIL: mcp.configure did not return the stored command" >&2
  Q "$A" mcp configure --command "$CONFIG_CMD" --json >&2 || true
  exit 1
fi

# Without the grant the relay must refuse (outbound side, on A).
if Q "$A" mcp listen --to bob --json 2>/dev/null | jq -e '.ok == false and .error.code == "capability_denied"' >/dev/null; then
  echo "PASS: mcp.listen denied without mcp.transport grant"
else
  echo "FAIL: mcp.listen should be denied without a grant" >&2
  exit 1
fi

Q "$A" access allow --subject "$B_PID" --capability mcp.transport --json >/dev/null
Q "$B" access allow --subject "$A_PID" --capability mcp.transport --json >/dev/null

if Q "$A" peer show bob --json | jq -e '.ok and .result.mcp_transport_granted == true' >/dev/null; then
  echo "PASS: peer.show reports mcp.transport granted"
else
  echo "FAIL: peer.show should report mcp_transport_granted=true" >&2
  exit 1
fi

SOCK=$(Q "$A" mcp listen --to bob --json | jq -r .result.socket)
if [ -z "$SOCK" ] || [ "$SOCK" = "null" ]; then
  echo "FAIL: mcp.listen returned no socket" >&2
  Q "$A" mcp listen --to bob --json >&2 || true
  exit 1
fi

if ! python3 "$root/scripts/mcp-fixture.py" drive-uds "$root/target/release/idfon-mcp" "$SOCK"; then
  echo "FAIL: MCP round trip through the daemon relay" >&2
  echo "--- A log ---" >&2; tail -20 "$work/a.log" >&2
  echo "--- B log ---" >&2; tail -20 "$work/b.log" >&2
  exit 1
fi

echo "PASS: daemon relay round trip over idfon/mcp/1 (grant-gated, both directions)"