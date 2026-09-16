#!/bin/sh
set -eu

# M4 acceptance: an Eve approval request crosses idfon, a deny does not execute
# the tool, and an approve resumes the parked turn and executes it.

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

work=$(mktemp -d /tmp/idfon-eve-e2e.XXXXXX)
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
printf '%064d' 17 > "$work/holder.key"

"$root/target/release/idfond" --socket "$A" --data-dir "$work/a" >"$work/a.log" 2>&1 &
pids="$pids $!"
for _ in $(seq 1 150); do
  if "$NUF" --socket "$A" status --json >/dev/null 2>&1; then break; fi
  sleep 0.1
done
A_PID=$("$NUF" --socket "$A" status --json | jq -r .result.identity.public_key)
HOLDER_TICKET=$("$HOLDER" --key-file "$work/holder.key" ticket --subject "$A_PID" --capability consent.approve)

"$HOLDER" --key-file "$work/holder.key" serve --socket "$HOLDER_SOCK" \
  --allow "$A_PID" >"$work/holder.ticket" 2>"$work/holder.log" &
pids="$pids $!"
for _ in $(seq 1 150); do
  if [ -s "$work/holder.ticket" ]; then break; fi
  sleep 0.1
done
HOLDER_ADDR=$(head -n 1 "$work/holder.ticket")
HOLDER_PID=$(printf '%s' "$HOLDER_ADDR" | jq -r .id)

app="$work/app"
mkdir -p "$app"
cp -R "$root/scripts/eve-channel-app/." "$app/"
mkdir -p "$app/agent/tools"
cat > "$app/agent/agent.ts" <<'EOF'
import { defineAgent } from "eve";
import { mockModel } from "eve/evals";

const requested = new Set<string>();

export default defineAgent({
  model: mockModel(({ lastUserMessage }) => {
    const callTool =
      (lastUserMessage === "deny" || lastUserMessage === "approve") &&
      !requested.has(lastUserMessage);
    if (callTool) requested.add(lastUserMessage);
    return callTool
      ? { toolCalls: [{ name: "approved_action", input: { value: "m4" } }] }
      : `reply from eve: ${lastUserMessage}`;
  }),
  modelContextWindowTokens: 4096,
});
EOF
cat > "$app/agent/tools/approved_action.ts" <<'EOF'
import { appendFile } from "node:fs/promises";
import { defineTool } from "eve/tools";
import { always } from "eve/tools/approval";
import { z } from "zod";

export default defineTool({
  description: "Run the approval-gated M4 action.",
  inputSchema: z.object({ value: z.string() }),
  approval: ({ session }) =>
    session.auth.current?.attributes?.capabilities?.includes("consent.approve")
      ? "user-approval"
      : { type: "denied", reason: "idfon grant consent.approve is required" },
  async execute({ value }) {
    console.error("M4_TOOL_EXECUTED");
    await appendFile("m4-tool-executed.log", `${value}\n`);
    return { status: "executed", value };
  },
});
EOF
cat > "$app/package.json" <<EOF
{
  "name": "idfon-eve-m4-fixture",
  "private": true,
  "type": "module",
  "dependencies": {
    "eve": "0.55.0",
    "idfon-eve-channel": "file:$integration"
  }
}
EOF
# The fixture uses a fixed secret; only the bridge port is selected dynamically.
bridge_port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)
# Use a second free port for Eve and patch the fixture's bridge URL.
eve_port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)
sed -i '' "s/18766/$bridge_port/" "$app/agent/extensions/idfon.ts"
(
  cd "$app"
  npm install --no-audit --no-fund --silent
  npx eve build >"$work/eve-build.log" 2>&1
  npx eve start --host 127.0.0.1 --port "$eve_port" >"$work/eve.log" 2>&1
) &
pids="$pids $!"
for _ in $(seq 1 200); do
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

"$NUF" --socket "$A" peer add "$HOLDER_PID" --name eve-holder \
  --endpoint-id "$HOLDER_PID" --endpoint-addr "$HOLDER_ADDR" --json >/dev/null
"$NUF" --socket "$A" access allow --subject "$HOLDER_PID" \
  --capability message.send --json >/dev/null
"$NUF" --socket "$A" events --follow --type message.received >"$work/events.log" 2>&1 &
pids="$pids $!"

request_id_at() {
  python3 - "$work/events.log" "$1" <<'PY'
import base64
import json
import sys

want = int(sys.argv[2])
requests = []
for line in open(sys.argv[1]):
    try:
        text = json.loads(line)["data"]["text"]
    except (ValueError, KeyError, TypeError):
        continue
    if not text.startswith("IDFON-HITL/1\n"): 
        continue
    encoded = next(line[8:] for line in text.splitlines() if line.startswith("payload="))
    requests.append(json.loads(base64.b64decode(encoded)))
if len(requests) < want:
    raise SystemExit(1)
print(requests[want - 1][0]["requestId"])
PY
}

send_response() {
  send_response_json=$("$NUF" --socket "$A" send "$HOLDER_PID" --text "$1" \
    --idempotency-key "$2" --capability-ticket "$HOLDER_TICKET" --retries 5 --json)
  send_response_op=$(printf '%s' "$send_response_json" | jq -r '.result.operation_id // .operation_id')
  "$NUF" --socket "$A" operation wait "$send_response_op" --timeout-ms 60000 --json >"$3"
}

hitl_response() {
  python3 - "$1" "$2" <<'PY'
import base64
import json
import sys

payload = json.dumps([{"requestId": sys.argv[1], "optionId": sys.argv[2]}], separators=(",", ":"))
print("IDFON-HITL-RESPONSE/1\npayload=" + base64.b64encode(payload.encode()).decode())
PY
}

"$NUF" --socket "$A" send "$HOLDER_PID" --text deny \
  --idempotency-key eve-channel-m4-deny \
  --capability-ticket "$HOLDER_TICKET" --retries 2 >"$work/send-deny.out"
for _ in $(seq 1 200); do
  if [ "$(grep -c 'IDFON-HITL/1' "$work/events.log" || true)" -ge 1 ]; then break; fi
  sleep 0.1
done
request_id=$(request_id_at 1)
sleep 3
hitl_response "$request_id" cancel >"$work/deny-response.txt"
send_response "$(cat "$work/deny-response.txt")" \
  eve-channel-m4-deny-response "$work/respond-deny.out"
for _ in $(seq 1 200); do
  if grep -q "reply from eve: deny" "$work/events.log"; then break; fi
  sleep 0.1
done
grep -q "reply from eve: deny" "$work/events.log"
sleep 3
if grep -q "M4_TOOL_EXECUTED" "$work/eve.log"; then
  echo "FAIL: denied approval executed the tool" >&2
  exit 1
fi

"$NUF" --socket "$A" send "$HOLDER_PID" --text approve \
  --idempotency-key eve-channel-m4-approve \
  --capability-ticket "$HOLDER_TICKET" --retries 2 >"$work/send-approve.out"
for _ in $(seq 1 200); do
  if [ "$(grep -c 'IDFON-HITL/1' "$work/events.log" || true)" -ge 2 ]; then break; fi
  sleep 0.1
done
request_id=$(request_id_at 2)
sleep 3
hitl_response "$request_id" approve >"$work/approve-response.txt"
send_response "$(cat "$work/approve-response.txt")" \
  eve-channel-m4-approve-response "$work/respond-approve.out"
for _ in $(seq 1 200); do
  if grep -q "M4_TOOL_EXECUTED" "$work/eve.log"; then break; fi
  sleep 0.1
done
grep -q "M4_TOOL_EXECUTED" "$work/eve.log"
for _ in $(seq 1 100); do
  if "$NUF" --socket "$A" events --type message.received --json 2>/dev/null |
      grep -q 'reply from eve: approve'; then break; fi
  sleep 0.1
done
"$NUF" --socket "$A" events --type message.received --json 2>/dev/null |
  grep -q 'reply from eve: approve'
echo "PASS: idfon HITL request, deny, approve, and durable resume"
