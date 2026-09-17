#!/bin/sh
set -eu

# R1 acceptance: two idfon peers share one Eve room session and both receive
# the agent reply under the same conversation.
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
integration="$root/integrations/eve-idfon-channel"

(
  cd "$integration"
  pnpm build >/dev/null
)
cargo build --release -p idfond -p idfon-cli -p eve-idfon-channel >/dev/null
codesign --force -s - target/release/idfond >/dev/null

work=$(mktemp -d /tmp/idfon-eve-room-e2e.XXXXXX)
pids=""
cleanup() {
  [ -n "$pids" ] && kill $pids 2>/dev/null || true
  [ -n "$pids" ] && wait $pids 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

NUF="$root/target/release/idfon"
HOLDER="$root/target/release/eve-idfon-channel"
HOLDER_SOCK="$work/holder.sock"
mkdir -p "$work/a" "$work/b"
printf '%064d' 17 > "$work/holder.key"

for who in a b; do
  "$root/target/release/idfond" --socket "$work/$who/idfond.sock" \
    --data-dir "$work/$who" >"$work/$who.log" 2>&1 &
  pids="$pids $!"
done
sock() { printf '%s' "$work/$1/idfond.sock"; }
for who in a b; do
  for _ in $(seq 1 150); do
    if "$NUF" --socket "$(sock "$who")" status --json >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
done

A_PID=$("$NUF" --socket "$(sock a)" status --json | jq -r .result.identity.public_key)
B_PID=$("$NUF" --socket "$(sock b)" status --json | jq -r .result.identity.public_key)
A_TICKET=$("$HOLDER" --key-file "$work/holder.key" ticket --subject "$A_PID")
B_TICKET=$("$HOLDER" --key-file "$work/holder.key" ticket --subject "$B_PID")

"$HOLDER" --key-file "$work/holder.key" serve --socket "$HOLDER_SOCK" \
  --allow "$A_PID" --allow "$B_PID" >"$work/holder.ticket" 2>"$work/holder.log" &
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
cat > "$app/package.json" <<EOF
{
  "name": "idfon-eve-room-fixture",
  "private": true,
  "type": "module",
  "dependencies": {
    "eve": "0.55.0",
    "eve-idfon-channel": "file:$integration"
  }
}
EOF
bridge_port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)
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

for who in a b; do
  "$NUF" --socket "$(sock "$who")" peer add "$HOLDER_PID" --name eve-holder \
    --endpoint-id "$HOLDER_PID" --endpoint-addr "$HOLDER_ADDR" --json >/dev/null
  for capability in message.send message.receive; do
    "$NUF" --socket "$(sock "$who")" access allow --subject "$HOLDER_PID" \
      --capability "$capability" --json >/dev/null
  done
done

"$NUF" --socket "$(sock a)" events --follow --type message.received >"$work/a.events" 2>&1 &
pids="$pids $!"
"$NUF" --socket "$(sock b)" events --follow --type message.received >"$work/b.events" 2>&1 &
pids="$pids $!"
sleep 0.5

ROOM="r_eve_room_e2e"
"$NUF" --socket "$(sock a)" send "$HOLDER_PID" --text hello-a \
  --conversation "$ROOM" --idempotency-key eve-room-a \
  --capability-ticket "$A_TICKET" --retries 2 >/dev/null
for _ in $(seq 1 250); do
  if grep -q "reply from eve: hello-a" "$work/a.events" 2>/dev/null; then break; fi
  sleep 0.1
done
"$NUF" --socket "$(sock b)" send "$HOLDER_PID" --text hello-b \
  --conversation "$ROOM" --idempotency-key eve-room-b \
  --capability-ticket "$B_TICKET" --retries 2 >/dev/null

for _ in $(seq 1 250); do
  if jq -e --arg room "$ROOM" \
      '[.messages[] | select(.conversation == $room and .content.text == "reply from eve: hello-b")] | length > 0' \
      "$work/a/state.json" >/dev/null 2>&1 \
     && jq -e --arg room "$ROOM" \
      '[.messages[] | select(.conversation == $room and .content.text == "reply from eve: hello-b")] | length > 0' \
      "$work/b/state.json" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

jq -e --arg room "$ROOM" \
  '[.messages[] | select(.conversation == $room and .content.text == "reply from eve: hello-b")] | length > 0' \
  "$work/a/state.json" >/dev/null
jq -e --arg room "$ROOM" \
  '[.messages[] | select(.conversation == $room and .content.text == "reply from eve: hello-b")] | length > 0' \
  "$work/b/state.json" >/dev/null
echo "PASS: two idfon peers shared one Eve room session and both received the reply"
