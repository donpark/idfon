#!/bin/sh
set -eu

# M5 acceptance: an Eve agent uses the extension's outbound idfon tool to
# message a second Eve agent; the reply returns without creating a loop.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
integration="$root/integrations/eve-idfon-channel"
(
  cd "$integration"
  npm install --no-audit --no-fund --silent
  npm run build >/dev/null
)

RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p idfond -p idfon-cli -p idfon-eve-channel
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond

work=$(mktemp -d /tmp/idfon-eve-a2a.XXXXXX)
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
C="$work/c/idfond.sock"
A_SOCK="$work/a-holder.sock"
B_SOCK="$work/b-holder.sock"
mkdir -p "$work/a" "$work/c"
printf '%064d' 17 >"$work/a-holder.key"
printf '%064d' 19 >"$work/b-holder.key"

"$root/target/release/idfond" --socket "$A" --data-dir "$work/a" >"$work/a-daemon.log" 2>&1 &
pids="$pids $!"
"$root/target/release/idfond" --socket "$C" --data-dir "$work/c" >"$work/c-daemon.log" 2>&1 &
pids="$pids $!"
for _ in $(seq 1 150); do
  if "$NUF" --socket "$A" status --json >/dev/null 2>&1 && \
     "$NUF" --socket "$C" status --json >/dev/null 2>&1; then break; fi
  sleep 0.1
done
C_PID=$("$NUF" --socket "$C" status --json | jq -r .result.identity.public_key)
# Derive both stable holder IDs from their signing keys before binding sockets.
A_TICKET=$($HOLDER --key-file "$work/a-holder.key" ticket --subject "$C_PID")
A_HOLDER_PID=$(printf '%s' "$A_TICKET" | jq -r .issuer)
B_TICKET=$($HOLDER --key-file "$work/b-holder.key" ticket --subject "$A_HOLDER_PID")
B_PID=$(printf '%s' "$B_TICKET" | jq -r .issuer)
A_REPLY_TICKET=$($HOLDER --key-file "$work/a-holder.key" ticket --subject "$B_PID")
printf '%s' "$B_TICKET" >"$work/b-reply-ticket.json"
printf '%s' "$A_REPLY_TICKET" >"$work/a-reply-ticket.json"

"$HOLDER" --key-file "$work/a-holder.key" serve --socket "$A_SOCK" \
  --reply-ticket-file "$work/b-reply-ticket.json" \
  >"$work/a-holder.ticket" 2>"$work/a-holder.log" &
pids="$pids $!"
"$HOLDER" --key-file "$work/b-holder.key" serve --socket "$B_SOCK" \
  --reply-ticket-file "$work/a-reply-ticket.json" \
  >"$work/b-holder.ticket" 2>"$work/b-holder.log" &
pids="$pids $!"
for _ in $(seq 1 150); do
  if [ -s "$work/a-holder.ticket" ] && [ -s "$work/b-holder.ticket" ]; then break; fi
  sleep 0.1
done
A_ADDR=$(head -n 1 "$work/a-holder.ticket")
B_ADDR=$(head -n 1 "$work/b-holder.ticket")

port() {
  python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}
A_BRIDGE_PORT=$(port)
A_EVE_PORT=$(port)
B_BRIDGE_PORT=$(port)
B_EVE_PORT=$(port)

make_app() {
  app=$1
  cp -R "$root/scripts/eve-channel-app/." "$app/"
  mkdir -p "$app/agent"
  cat >"$app/package.json" <<EOF
{
  "name": "idfon-eve-m5-fixture",
  "private": true,
  "type": "module",
  "dependencies": {
    "eve": "0.54.5",
    "@idfon/eve-channel": "file:$integration"
  }
}
EOF
}

A_APP="$work/a-app"
B_APP="$work/b-app"
mkdir -p "$A_APP" "$B_APP"
make_app "$A_APP"
make_app "$B_APP"
sed -i '' "s/18766/$A_BRIDGE_PORT/" "$A_APP/agent/extensions/idfon.ts"
sed -i '' "s/18766/$B_BRIDGE_PORT/" "$B_APP/agent/extensions/idfon.ts"

python3 - "$B_PID" "$B_TICKET" >"$A_APP/agent/m5-target.ts" <<'PY'
import json
import sys
print("export const target = " + json.dumps({
    "peerId": sys.argv[1],
    "endpointId": sys.argv[1],
    "capabilityTicket": json.loads(sys.argv[2]),
}) + " as const;")
PY
cat >"$A_APP/agent/agent.ts" <<'EOF'
import { defineAgent } from "eve";
import { mockModel } from "eve/evals";
import { target } from "./m5-target";

let sent = false;
export default defineAgent({
  model: mockModel(({ lastUserMessage }) => {
    if (lastUserMessage?.startsWith("reply from eve-b:")) {
      console.error("M5_A2A_REPLY_RECEIVED");
      return "";
    }
    if (lastUserMessage === "send to B" && !sent) {
      sent = true;
      return {
        toolCalls: [{
          name: "idfon__send",
          input: { ...target, text: "hello from eve-a" },
        }],
      };
    }
    return `reply from eve-a: ${lastUserMessage}`;
  }),
  modelContextWindowTokens: 4096,
});
EOF
cat >"$B_APP/agent/agent.ts" <<'EOF'
import { defineAgent } from "eve";
import { mockModel } from "eve/evals";

export default defineAgent({
  model: mockModel(({ lastUserMessage }) => `reply from eve-b: ${lastUserMessage}`),
  modelContextWindowTokens: 4096,
});
EOF

(
  cd "$A_APP"
  npm install --no-audit --no-fund --silent
  npx eve build >"$work/a-eve-build.log" 2>&1
  npx eve start --host 127.0.0.1 --port "$A_EVE_PORT" >"$work/a-eve.log" 2>&1
) &
pids="$pids $!"
(
  cd "$B_APP"
  npm install --no-audit --no-fund --silent
  npx eve build >"$work/b-eve-build.log" 2>&1
  npx eve start --host 127.0.0.1 --port "$B_EVE_PORT" >"$work/b-eve.log" 2>&1
) &
pids="$pids $!"
for _ in $(seq 1 250); do
  if curl -sS -o /dev/null "http://127.0.0.1:$A_EVE_PORT/idfon/turn" 2>/dev/null && \
     curl -sS -o /dev/null "http://127.0.0.1:$B_EVE_PORT/idfon/turn" 2>/dev/null; then break; fi
  sleep 0.1
done

node "$integration/bridge.mjs" --socket "$A_SOCK" \
  --target "http://127.0.0.1:$A_EVE_PORT" --secret m2-test-secret --port "$A_BRIDGE_PORT" \
  >"$work/a-bridge.out" 2>"$work/a-bridge.log" &
pids="$pids $!"
node "$integration/bridge.mjs" --socket "$B_SOCK" \
  --target "http://127.0.0.1:$B_EVE_PORT" --secret m2-test-secret --port "$B_BRIDGE_PORT" \
  >"$work/b-bridge.out" 2>"$work/b-bridge.log" &
pids="$pids $!"
for _ in $(seq 1 150); do
  if curl -fsS "http://127.0.0.1:$A_BRIDGE_PORT/health" >/dev/null 2>&1 && \
     curl -fsS "http://127.0.0.1:$B_BRIDGE_PORT/health" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
guard=$(curl -fsS -X POST "http://127.0.0.1:$A_EVE_PORT/idfon/turn" \
  -H 'content-type: application/json' -H 'x-idfon-channel-secret: m2-test-secret' \
  -d '{"message_id":"m5-guard","peer_id":"guard-peer","endpoint_id":"guard-peer","text":"loop","a2a_depth":2}')
printf '%s' "$guard" | grep -q 'a2a_loop_guard'

"$NUF" --socket "$C" peer add "$A_HOLDER_PID" --name eve-a \
  --endpoint-id "$A_HOLDER_PID" --endpoint-addr "$A_ADDR" --json >/dev/null
"$NUF" --socket "$C" access allow --subject "$A_HOLDER_PID" \
  --capability message.send --json >/dev/null
"$NUF" --socket "$C" events --follow --type message.received >"$work/c-events.log" 2>&1 &
pids="$pids $!"

"$NUF" --socket "$C" send "$A_HOLDER_PID" --text "send to B" \
  --idempotency-key eve-channel-m5-start --capability-ticket "$A_TICKET" \
  --retries 5 >"$work/start.out"
for _ in $(seq 1 400); do
  if grep -q "reply from eve-a: send to B" "$work/c-events.log"; then break; fi
  sleep 0.1
done
grep -q "reply from eve-a: send to B" "$work/c-events.log"
for _ in $(seq 1 400); do
  if grep -q "M5_A2A_REPLY_RECEIVED" "$work/a-eve.log"; then break; fi
  sleep 0.1
done
grep -q "M5_A2A_REPLY_RECEIVED" "$work/a-eve.log"
if grep -q "turn delivery failed\|holder error\|HTTP 5" "$work/a-bridge.log" "$work/b-bridge.log" "$work/a-holder.log" "$work/b-holder.log"; then
  echo "FAIL: A2A transport error" >&2
  cat "$work/a-bridge.log" "$work/b-bridge.log" "$work/a-holder.log" "$work/b-holder.log" >&2
  exit 1
fi
echo "PASS: Eve A -> idfon peer tool -> Eve B -> bounded A2A reply"
