#!/bin/sh
set -eu

# M3 acceptance: an Eve tool stores output bytes through the holder, the
# agent returns an IDFON-DATA/1 ticket, and the peer fetches the blob.

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

work=$(mktemp -d /tmp/idfon-eve-media-out.XXXXXX)
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
printf '%064d' 23 >"$work/holder.key"

"$root/target/release/idfond" --socket "$A" --data-dir "$work/a" >"$work/a.log" 2>&1 &
pids="$pids $!"
for _ in $(seq 1 150); do
  if "$NUF" --socket "$A" status --json >/dev/null 2>&1; then break; fi
  sleep 0.1
done
A_PID=$("$NUF" --socket "$A" status --json | jq -r .result.identity.public_key)
HOLDER_TICKET=$($HOLDER --key-file "$work/holder.key" ticket --subject "$A_PID")
"$HOLDER" --key-file "$work/holder.key" serve --socket "$HOLDER_SOCK" \
  --allow "$A_PID" --blob-dir "$work/holder-blobs" \
  >"$work/holder.ticket" 2>"$work/holder.log" &
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
cat >"$app/agent/agent.ts" <<'EOF'
import { defineAgent } from "eve";
import { mockModel } from "eve/evals";

let uploaded = false;
export default defineAgent({
  model: mockModel(({ lastUserMessage, toolResults }) => {
    const result = toolResults.find((item) => item.name === "idfon__put");
    if (result && !result.isError) {
      return { text: (result.output as { envelope: string }).envelope };
    }
    if (lastUserMessage === "send file" && !uploaded) {
      uploaded = true;
      return {
        toolCalls: [{
          name: "idfon__put",
          input: { bytesBase64: "ZXZlLWZpbGUtb3V0Cg==" },
        }],
      };
    }
    return `reply from eve: ${lastUserMessage}`;
  }),
  modelContextWindowTokens: 4096,
});
EOF
cat >"$app/package.json" <<EOF
{
  "name": "idfon-eve-m3-file-out-fixture",
  "private": true,
  "type": "module",
  "dependencies": {
    "eve": "0.55.0",
    "idfon-eve-channel": "file:$integration"
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

"$NUF" --socket "$A" peer add "$HOLDER_PID" --name eve-holder \
  --endpoint-id "$HOLDER_PID" --endpoint-addr "$HOLDER_ADDR" --json >/dev/null
"$NUF" --socket "$A" access allow --subject "$HOLDER_PID" \
  --capability message.send --json >/dev/null
"$NUF" --socket "$A" events --follow --type message.received >"$work/events.log" 2>&1 &
pids="$pids $!"
"$NUF" --socket "$A" send "$HOLDER_PID" --text "send file" \
  --idempotency-key eve-channel-m3-file-out --capability-ticket "$HOLDER_TICKET" \
  --retries 2 >"$work/send.out"
for _ in $(seq 1 300); do
  if grep -q 'IDFON-DATA/1' "$work/events.log"; then break; fi
  sleep 0.1
done
grep -q 'IDFON-DATA/1' "$work/events.log"

python3 - "$work/events.log" >"$work/blob.ticket" <<'PY'
import json
import sys
for line in open(sys.argv[1]):
    try:
        text = json.loads(line)["data"]["text"]
    except (ValueError, KeyError, TypeError):
        continue
    if not text.startswith("IDFON-DATA/1"):
        continue
    for field in text.splitlines():
        if field.startswith("ticket="):
            print(field[7:])
            raise SystemExit
raise SystemExit("no blob ticket")
PY
"$NUF" --socket "$A" get "$(cat "$work/blob.ticket")" --out "$work/out.bin" >/dev/null
printf 'eve-file-out\n' >"$work/expected.bin"
cmp "$work/expected.bin" "$work/out.bin"
if grep -q "blob put\|HTTP 5\|holder error" "$work/bridge.log" "$work/holder.log"; then
  echo "FAIL: blob put failed" >&2
  cat "$work/bridge.log" "$work/holder.log" >&2
  exit 1
fi
echo "PASS: Eve idfon__put -> IDFON-DATA/1 -> peer blob fetch"
