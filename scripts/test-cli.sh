#!/bin/sh
set -eu

# CLI surface test: spins up two throwaway daemons and exercises every idfon
# command and flag not already covered by the specialized e2e scripts
# (stream-e2e.sh / fanout-e2e.sh cover live streaming; this covers the rest).
#
# Verified: status, shutdown, identity (create/use/delete/list + --identity
# flag), peer (add/list/show/resolve/status/update/remove), access
# (allow/check/ticket), send --text (+ --idempotency-key), send --file,
# recv (+ --out/--from), put (+ --resource-id/--json), get, events (+ --type),
# wait, operation (get/wait/cancel), --json envelopes, and documented failure
# paths (missing peers, bogus tickets/operations, recv timeout).
#
# PASS requires every check to pass; exits non-zero on the first failure.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# Same build/sign preamble as test-e2e.sh: the thin idfond links the vendored
# dylib, and a relink can leave a stale ad-hoc signature the kernel kills.
RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p idfond -p idfon-cli
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond

work=$(mktemp -d /tmp/idfon-cli.XXXXXX)
pids=""
cleanup() {
  if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

NUF="$root/target/release/idfon"
A="$work/a/idfond.sock"
B="$work/b/idfond.sock"
Q() { # idfon against a socket, passthrough
  "$NUF" --socket "$1" "${@:2}"
}

mkdir -p "$work/a" "$work/b"
"$root/target/release/idfond" --socket "$A" --data-dir "$work/a" &
pids="$pids $!"
"$root/target/release/idfond" --socket "$B" --data-dir "$work/b" &
pids="$pids $!"

wait_ready() { # socket label
  for _ in $(seq 1 100); do
    if "$NUF" --socket "$1" status --json >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "FAIL: daemon $2 not ready" >&2
  exit 1
}
wait_ready "$A" A
wait_ready "$B" B

ok() { # label cmd...
  label=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $label"
  else
    echo "FAIL: $label" >&2
    exit 1
  fi
}
fails() { # label cmd...  (command must exit non-zero)
  label=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: $label (expected non-zero exit)" >&2
    exit 1
  else
    echo "PASS: $label"
  fi
}

# --- status -----------------------------------------------------------------
ok "status (human)" sh -c "\"$NUF\" --socket '$A' status | grep -q ready"
S=$(Q "$A" status --json)
echo "$S" | jq -e '.ok == true and .result.ready == true and .result.identity.name' >/dev/null
echo "PASS: status --json envelope"

# --- identity ---------------------------------------------------------------
ORIG_ID=$(echo "$S" | jq -r '.result.identity.name')
ok "identity list" Q "$A" identity list --json
ok "identity create work" Q "$A" identity create work --json
Q "$A" identity list --json | jq -e --arg orig "$ORIG_ID" \
  '[.result.identities[].name] | index("work") and index($orig)' >/dev/null
echo "PASS: identity list shows created + original"
ok "identity use work" Q "$A" identity use work --json
Q "$A" identity list --json | jq -e '.result.identities | map(select(.name == "work" and .active == true)) | length == 1' >/dev/null
echo "PASS: identity use switches active"
S=$(Q "$A" status --json)   # fresh invocation: session identity = active identity
echo "$S" | jq -e '.result.identity.name == "work"' >/dev/null
echo "PASS: status reflects active identity across invocations"
S=$(Q "$A" --identity work status --json)
echo "$S" | jq -e '.result.identity.name == "work"' >/dev/null
echo "PASS: --identity flag selects identity"
fails "identity delete active" Q "$A" identity delete work --json
ok "identity --identity flag" Q "$A" --identity "$ORIG_ID" status --json
ok "identity use back" Q "$A" identity use "$ORIG_ID" --json
ok "identity delete work" Q "$A" identity delete work --json

# --- peer -------------------------------------------------------------------
A_EP=$(Q "$A" status --json | jq -r .result.identity.endpoint_id)
A_PID=$(Q "$A" status --json | jq -r .result.identity.public_key)
A_ADDR=$(Q "$A" status --json | jq -r '.result.ticket | implode')
B_EP=$(Q "$B" status --json | jq -r .result.identity.endpoint_id)
B_PID=$(Q "$B" status --json | jq -r .result.identity.public_key)
B_ADDR=$(Q "$B" status --json | jq -r '.result.ticket | implode')
ok "peer add" Q "$A" peer add "$B_PID" --name bob --endpoint-id "$B_EP" --endpoint-addr "$B_ADDR" --json
ok "peer add (reverse)" Q "$B" peer add "$A_PID" --name alice --endpoint-id "$A_EP" --endpoint-addr "$A_ADDR" --json
Q "$A" peer list --json | jq -e '.result.peers | map(select(.name == "bob")) | length == 1' >/dev/null
echo "PASS: peer list"
S=$(Q "$A" peer show bob --json)
echo "$S" | jq -e '.result.peer.name == "bob" and .result.peer.endpoint_id == "'"$B_EP"'"' >/dev/null
echo "PASS: peer show"
ok "peer resolve" Q "$A" peer resolve bob --json
ok "peer status" Q "$A" peer status bob --json
ok "peer update" Q "$A" peer update bob --name robert --json
S=$(Q "$A" peer show robert --json)
echo "$S" | jq -e '.result.peer.name == "robert"' >/dev/null
echo "PASS: peer update visible in show"
ok "peer update name back" Q "$A" peer update robert --name bob --json
fails "peer show missing" Q "$A" peer show nobody --json
fails "peer resolve missing" Q "$A" peer resolve nobody --json
fails "peer status missing" Q "$A" peer status nobody --json

# --- access -----------------------------------------------------------------
ok "access allow (A->B send)" Q "$A" access allow --subject "$B_PID" --capability message.send --json
ok "access allow (B->A send)" Q "$B" access allow --subject "$A_PID" --capability message.send --json
ok "access allow (B->A receive)" Q "$B" access allow --subject "$A_PID" --capability message.receive --json
S=$(Q "$A" access check --subject "$B_PID" --capability message.send --json)
echo "$S" | jq -e '.result.allowed == true' >/dev/null
echo "PASS: access check granted"
S=$(Q "$A" access check --subject "$A_PID" --capability message.send --json)
echo "$S" | jq -e '.result.allowed == false' >/dev/null
echo "PASS: access check not granted"
fails "access check unknown capability" Q "$A" access check --subject "$B_PID" --capability bogus.cap --json
T=$(Q "$A" access ticket --subject "$B_PID" --capability message.send)
echo "$T" | jq -e '. != null and . != ""' >/dev/null
echo "PASS: access ticket mints JSON capability ticket"

# --- send --text / events / wait / operation --------------------------------
CURSOR=$(Q "$B" events --json | jq -r '.result.events | last | .cursor // empty')
S=$(Q "$A" send bob --text "hello from cli test" --json)
echo "$S" | jq -e '.ok == true and .result.operation_id != ""' >/dev/null
echo "PASS: send --text --json"
OPID=$(echo "$S" | jq -r .result.operation_id)
W=$(Q "$B" wait --type message.received --after "$CURSOR" --json)
echo "$W" | jq -e '.result.events[0].data.text == "hello from cli test"' >/dev/null
echo "PASS: wait receives text event with body"
S=$(Q "$B" events --json --type message.received)
echo "$S" | jq -e '.result.events | length >= 1' >/dev/null
echo "PASS: events --type filter"
S=$(Q "$B" events --json --type test.never)
echo "$S" | jq -e '.result.events | length == 0' >/dev/null
echo "PASS: events --type with no matches is empty"
W=$(Q "$B" wait --type test.never --timeout-ms 300 --json)
echo "$W" | jq -e '.ok == true and (.result.events | length == 0)' >/dev/null
echo "PASS: wait timeout returns empty success"
S=$(Q "$A" operation get "$OPID" --json)
echo "$S" | jq -e '.result.operation.status == "delivered"' >/dev/null
echo "PASS: operation get delivered"
S=$(Q "$A" operation wait "$OPID" --json)
echo "$S" | jq -e '.result.operation.status == "delivered"' >/dev/null
echo "PASS: operation wait terminal"
fails "operation get missing" Q "$A" operation get op_nope --json
fails "operation cancel missing" Q "$A" operation cancel op_nope --json
ok "send --text --idempotency-key" Q "$A" send bob --text dedupe --idempotency-key cli-test-k1 --json
ok "send --text --idempotency-key (resend)" Q "$A" send bob --text dedupe --idempotency-key cli-test-k1 --json
fails "send without PEER" Q "$A" send --text hi --json

# --- put/get variations (chunked round trip lives in test-e2e.sh) ------------
printf 'cli-test-payload' > "$work/payload.bin"
T=$(Q "$A" put --resource-id cli-test-res < "$work/payload.bin")
Q "$A" get "$T" > "$work/payload.roundtrip"
cmp -s "$work/payload.bin" "$work/payload.roundtrip"
echo "PASS: put --resource-id / get round trip"
S=$(Q "$A" put --json < "$work/payload.bin")
echo "$S" | jq -e '.result.blob_ticket != "" and .result.size_bytes > 0' >/dev/null
echo "PASS: put --json envelope"
fails "get bogus ticket" Q "$A" get blob-does-not-exist
fails "get garbage ticket" Q "$A" get not-a-ticket

# --- signaled transfer with recv --out/--from --------------------------------
# recv baselines on the latest cursor when it starts, so it must be running
# (with its baseline taken) before the send completes.
Q "$B" recv --out "$work/signaled.received" --from "$A_PID" --timeout-ms 30000 2>/dev/null < /dev/null &
recv_pid=$!
sleep 1
Q "$A" send bob --file --retries 2 < "$work/payload.bin" > /dev/null
if wait "$recv_pid"; then
  cmp -s "$work/payload.bin" "$work/signaled.received"
  echo "PASS: recv --out --from"
else
  echo "FAIL: recv --out --from" >&2
  exit 1
fi
fails "recv timeout" Q "$A" recv --timeout-ms 300 --json

# --- stream --list (publish/dial covered by stream-e2e.sh) -------------------
ok "send --stream --list" Q "$A" send --stream --list --json

# --- peer remove --------------------------------------------------------------
ok "peer remove" Q "$A" peer remove bob --json
Q "$A" peer list --json | jq -e '.result.peers | length == 0' >/dev/null
echo "PASS: peer remove leaves list empty"

# --- shutdown (last: A goes away here; do not touch A afterwards) ------------
ok "shutdown" Q "$A" shutdown
fails "shutdown when down (no auto-start)" Q "$A" shutdown

echo "PASS: idfon CLI surface test"
