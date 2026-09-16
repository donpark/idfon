#!/bin/sh
set -eu

# M3 acceptance: an IDFON-DATA/1 blob ticket becomes an Eve file part and
# fetchFile resolves the ticket through the holder's blob fetch path.

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
HOLDER_TICKET=$("$HOLDER" --key-file "$work/holder.key" ticket --subject "$A_PID")

"$HOLDER" --key-file "$work/holder.key" serve --socket "$HOLDER_SOCK" \
  --allow "$A_PID" --blob-dir "$work/holder-blobs" >"$work/holder.ticket" 2>"$work/holder.log" &
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
cat > "$app/agent/sandbox.ts" <<'EOF'
import { defineSandbox } from "eve/sandbox";
import { justbash } from "eve/sandbox/just-bash";

export default defineSandbox({ backend: justbash() });
EOF
cat > "$app/package.json" <<EOF
{
  "name": "idfon-eve-m3-fixture",
  "private": true,
  "type": "module",
  "dependencies": {
    "eve": "0.55.0",
    "just-bash": "^3.4.2",
    "@idfon/eve-channel": "file:$integration"
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

printf 'eve-m3-file-%s\n' "$(date +%s)" >"$work/input.txt"
blob_ticket=$("$NUF" --socket "$A" put --file "$work/input.txt")
size=$(wc -c <"$work/input.txt" | tr -d ' ')
payload=$(printf 'IDFON-DATA/1\nticket=%s\nsize=%s' "$blob_ticket" "$size")
"$NUF" --socket "$A" send "$HOLDER_PID" --text "$payload" \
  --idempotency-key eve-channel-m3 \
  --capability-ticket "$HOLDER_TICKET" --retries 2 >"$work/send.out"

for _ in $(seq 1 300); do
  if grep -q "reply from eve: Attached file (${size} bytes)" "$work/events.log"; then break; fi
  sleep 0.1
done

grep -q "reply from eve: Attached file (${size} bytes)" "$work/events.log"
fetched=$(find "$work/holder-blobs" -name '*.blob' -type f -print -quit)
test -n "$fetched"
cmp "$work/input.txt" "$fetched"
if grep -q "blob fetch\|HTTP 5\|holder error" "$work/bridge.log" "$work/holder.log"; then
  echo "FAIL: blob fetch failed" >&2
  cat "$work/bridge.log" "$work/holder.log" >&2
  exit 1
fi
echo "PASS: blob ticket -> Eve file part -> holder fetchFile round trip"
