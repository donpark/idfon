#!/bin/sh
set -eu

# M1 acceptance: a real daemon sends a signed, ticket-authorized text message
# to the standalone endpoint holder; the holder emits turn.in over UDS and
# sends reply.out back over idfon/message/1.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p idfond -p idfon-cli -p idfon-eve-channel
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond

work=$(mktemp -d /tmp/idfon-eve-holder.XXXXXX)
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
HOLDER="$root/target/release/idfon-eve-channel"
A="$work/a/idfond.sock"
HOLDER_SOCK="$work/holder.sock"
mkdir -p "$work/a"
printf '%064d' 11 > "$work/holder.key"

"$root/target/release/idfond" --socket "$A" --data-dir "$work/a" >"$work/a.log" 2>&1 &
pids="$pids $!"
for _ in $(seq 1 150); do
  if "$NUF" --socket "$A" status --json >/dev/null 2>&1; then break; fi
  sleep 0.1
done

A_PID=$("$NUF" --socket "$A" status --json | jq -r .result.identity.public_key)
HOLDER_TICKET=$("$HOLDER" --key-file "$work/holder.key" ticket --subject "$A_PID")
"$HOLDER" --key-file "$work/holder.key" serve \
  --socket "$HOLDER_SOCK" --allow "$A_PID" >"$work/holder.ticket" 2>"$work/holder.log" &
pids="$pids $!"
for _ in $(seq 1 150); do
  if [ -s "$work/holder.ticket" ]; then break; fi
  sleep 0.1
done
HOLDER_ADDR=$(head -n 1 "$work/holder.ticket")
HOLDER_PID=$(printf '%s' "$HOLDER_ADDR" | jq -r .id)

python3 "$root/scripts/eve-channel-holder-fixture.py" "$HOLDER_SOCK" "$A_PID" \
  >"$work/ipc.log" 2>"$work/ipc.err" &
pids="$pids $!"

"$NUF" --socket "$A" peer add "$HOLDER_PID" --name eve-holder \
  --endpoint-id "$HOLDER_PID" --endpoint-addr "$HOLDER_ADDR" --json >/dev/null
"$NUF" --socket "$A" access allow --subject "$HOLDER_PID" \
  --capability message.send --json >/dev/null

"$NUF" --socket "$A" events --follow --type message.received >"$work/events.log" 2>&1 &
pids="$pids $!"

"$NUF" --socket "$A" send "$HOLDER_PID" --text hello \
  --idempotency-key eve-holder-m1 \
  --capability-ticket "$HOLDER_TICKET" --retries 2 >"$work/send.out"

for _ in $(seq 1 150); do
  if grep -q "reply from eve holder" "$work/events.log" &&
      grep -q "IDFON-STATUS/1" "$work/events.log"; then break; fi
  sleep 0.1
done

python3 - "$work/ipc.log" "$work/events.log" <<'PY'
import json
import sys

ipc = open(sys.argv[1]).read().strip()
assert ipc, "IPC fixture produced no result"
result = json.loads(ipc)
assert result["turn"]["type"] == "turn.in"
assert result["turn"]["text"] == "hello"
assert result["ack"]["type"] == "reply.ack"
assert result["ack"]["status"] == "accepted"
assert result["status_ack"]["event"] == "turn.cancelled"
events = open(sys.argv[2]).read()
assert "reply from eve holder" in events, events
assert "IDFON-STATUS/1" in events, events
print("PASS: authenticated holder turn and reply over idfon/message/1 + UDS")
PY
