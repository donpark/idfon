#!/bin/sh
set -eu

# M1 acceptance for the MCP transport binding: newline-delimited JSON-RPC over
# idfon/mcp/1, a stock-stdio MCP scenario driven through the idfon-mcp bridge.
#
# The bridge is a byte pump. This test proves the wire binding only: discover,
# tools/list, tools/call, a relayed version error, a subscription notification,
# and framing preservation under escaped characters. No daemon is involved —
# the M1 node embeds idfon-core and owns its own key (see the plan).
#
# PASS requires every check to pass; exits non-zero on the first failure.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

cargo build --release -p idfon-mcp

work=$(mktemp -d /tmp/idfon-mcp.XXXXXX)
pids=""
cleanup() {
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    wait $pids 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

BIN="$root/target/release/idfon-mcp"
# Fixed hex keys: stable identity across runs, and this covers --key-file.
printf '%064d' 1 > "$work/serve.key"
printf '%064d' 2 > "$work/connect.key"

"$BIN" serve \
  --command "python3 $root/scripts/mcp-fixture.py server" \
  --key-file "$work/serve.key" \
  >"$work/serve.out" 2>"$work/serve.err" &
pids="$pids $!"

ticket=""
for _ in $(seq 1 150); do
  if [ -s "$work/serve.out" ]; then
    ticket=$(head -n 1 "$work/serve.out")
    break
  fi
  if ! kill -0 $pids 2>/dev/null; then
    echo "FAIL: idfon-mcp serve exited before printing a ticket" >&2
    cat "$work/serve.err" >&2
    exit 1
  fi
  sleep 0.1
done
if [ -z "$ticket" ]; then
  echo "FAIL: idfon-mcp serve printed no ticket" >&2
  cat "$work/serve.err" >&2
  exit 1
fi

if ! python3 "$root/scripts/mcp-fixture.py" drive "$BIN" "$ticket" "$work/connect.key"; then
  echo "FAIL: MCP round trip over idfon/mcp/1" >&2
  echo "--- serve stderr ---" >&2
  cat "$work/serve.err" >&2
  exit 1
fi

echo "PASS: idfon/mcp/1 round trip (discover, tools, version error, subscription, framing)"