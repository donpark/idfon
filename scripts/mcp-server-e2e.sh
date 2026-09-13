#!/bin/sh
set -eu

# M4 acceptance: idfon as an MCP server.
#
# `idfon-mcp-server` is a separate adapter over idfon-client that speaks MCP
# over stdio and exposes idfon capabilities as tools. Consent stays with the
# daemon: sending to an ungranted peer comes back as a tool error, sending to a
# granted peer delivers.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p idfond -p idfon-cli -p idfon-mcp-server
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond

work=$(mktemp -d /tmp/idfon-mcp-server.XXXXXX)
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
A="$work/a.sock"
B="$work/b.sock"
Q() { "$NUF" --socket "$1" "${@:2}"; }

mkdir -p "$work/a" "$work/b"
"$root/target/release/idfond" --socket "$A" --data-dir "$work/a" >"$work/a.log" 2>&1 &
pids="$pids $!"
"$root/target/release/idfond" --socket "$B" --data-dir "$work/b" >"$work/b.log" 2>&1 &
pids="$pids $!"

wait_ready() {
  for _ in $(seq 1 150); do
    "$NUF" --socket "$1" status --json >/dev/null 2>&1 && return 0
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
# carol is known but never granted, so the adapter must surface a denial.
CAROL="1111111111111111111111111111111111111111111111111111111111111111"
Q "$A" peer add "$CAROL" --name carol --endpoint-id "$CAROL" --endpoint-addr "{\"id\":\"$CAROL\"}" --json >/dev/null

Q "$A" access allow --subject "$B_PID" --capability message.send --json >/dev/null
Q "$B" access allow --subject "$A_PID" --capability message.receive --json >/dev/null

if ! python3 "$root/scripts/mcp-fixture.py" drive-server "$root/target/release/idfon-mcp-server" "$A"; then
  echo "FAIL: MCP client calls against the adapter" >&2
  echo "--- A log ---" >&2; tail -20 "$work/a.log" >&2
  echo "--- B log ---" >&2; tail -20 "$work/b.log" >&2
  exit 1
fi

for _ in $(seq 1 100); do
  if Q "$B" events --json | jq -e '[.result.events[].data.text] | index("hi from mcp")' >/dev/null; then
    echo "PASS: idfon-mcp-server tools (discover, list_peers, put_blob, grant-gated send)"
    exit 0
  fi
  sleep 0.1
done
echo "FAIL: peer B never received the adapter's message" >&2
exit 1