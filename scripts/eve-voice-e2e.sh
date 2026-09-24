#!/bin/sh
set -eu

# ai-voice-chat E2E: a real voice memo round-trip through the idfon channel.
#
# Requires AI_GATEWAY_API_KEY (GPT-Live voice session + gpt-6-luna delegation)
# and EVE_IDFON_MODEL (default anthropic/claude-haiku-4.5) for the eve agent.
#
# Flow: synthesize a question with `say` -> Ogg Opus (48k mono) -> blob put ->
# IDFON-RECORDING/1 envelope -> holder -> eve turn -> voice_reply tool ->
# GPT-Live -> reply WAV blob -> reply envelope text back to the peer.
#
# Asserts: reply text carries a transcript line and an IDFON-DATA/1 envelope;
# the envelope's ticket fetches bytes that parse as a valid WAV (24 kHz mono).

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

: "${AI_GATEWAY_API_KEY:?AI_GATEWAY_API_KEY must be set}"
model="${EVE_IDFON_MODEL:-anthropic/claude-haiku-4.5}"

integration="$root/integrations/eve-idfon-channel"
(
  cd "$integration"
  npm install --no-audit --no-fund --silent
  npm run build >/dev/null
)

RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p idfond -p idfon-cli -p eve-idfon-channel
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond

work=$(mktemp -d /tmp/idfon-voice-e2e.XXXXXX)
pids=""
cleanup() {
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  [ -n "$pids" ] && wait $pids 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

NUF="$root/target/release/idfon"
HOLDER="$root/target/release/eve-idfon-channel"
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

# Eve app: ai-voice-chat, real orchestrator model, per-run bridge port.
app="$work/app"
mkdir -p "$app"
cp -R "$root/agents/ai-voice-chat/agent" "$root/agents/ai-voice-chat/package.json" \
  "$root/agents/ai-voice-chat/package-lock.json" "$app/"
# Reuse the agent's installed node_modules; a fresh npm install adds minutes.
cp -R "$root/agents/ai-voice-chat/node_modules" "$app/node_modules"
# eve-idfon-channel is installed as a relative symlink into the repo; repoint
# it so the app builds outside the repo tree.
ln -sfn "$integration" "$app/node_modules/eve-idfon-channel"
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
  npx --offline eve build >"$work/eve-build.log" 2>&1
  npx --offline eve start --host 127.0.0.1 --port "$eve_port" >"$work/eve.log" 2>&1
) &
pids="$pids $!"
for _ in $(seq 1 300); do
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

# A spoken question with a distinctive answer, encoded as an idfon recording:
# 48 kHz mono Ogg Opus, exactly what the mac voice-memo path produces.
say -o "$work/question.aiff" "What is two plus two?"
ffmpeg -y -i "$work/question.aiff" -ar 48000 -ac 1 -c:a libopus -f ogg \
  "$work/question.opus" >/dev/null 2>&1
size=$(wc -c <"$work/question.opus" | tr -d ' ')
blob_ticket=$("$NUF" --socket "$A" put --file "$work/question.opus" --mime audio/opus)
duration_ms=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$work/question.opus" \
  | awk '{printf "%d", $1 * 1000}')
payload=$(printf 'IDFON-RECORDING/1\nid=%s\ncodec=opus\nchannels=1\nsample_rate=48000\nduration_ms=%s\nsender_id=%s\nticket=%s' \
  "$blob_ticket" "$duration_ms" "$A_PID" "$blob_ticket")

"$NUF" --socket "$A" send "$HOLDER_PID" --text "$payload" \
  --idempotency-key "eve-voice-e2e-$(date +%s)" \
  --capability-ticket "$HOLDER_TICKET" --retries 2 >"$work/send.out"

# The voice leg is slow: ~1s input + a GPT-Live session (up to ~30s) + model
# orchestration. Wait up to 3 minutes for the reply.
echo "waiting for spoken reply (GPT-Live session can take ~30s)..." >&2
for _ in $(seq 1 300); do
  if grep -q "IDFON-DATA/1" "$work/events.log" 2>/dev/null; then break; fi
  sleep 1
done
# The reply event's JSON carries the transcript plus the IDFON-DATA/1 envelope.
reply=$(grep "IDFON-DATA/1" "$work/events.log" | tail -n 1 || true)
if [ -z "$reply" ]; then
  echo "FAIL: no reply with an audio envelope" >&2
  tail -20 "$work/events.log" "$work/eve.log" "$work/bridge.log" >&2
  exit 1
fi

echo "$reply"
echo "$reply" | tee "$work/reply.line"

# 1. transcript present (the model quotes voice_reply's transcript)
# 2. an IDFON-DATA/1 envelope with a ticket exists in the reply
reply_ticket=$(printf '%s' "$reply" | grep -o 'ticket=[^ "]*' | tail -n 1 | cut -d= -f2)
if [ -z "$reply_ticket" ]; then
  echo "FAIL: reply has no IDFON-DATA/1 ticket" >&2
  echo "$reply" >&2
  exit 1
fi

# 3. the reply blob fetches and parses as a 24 kHz mono 16-bit WAV
"$NUF" --socket "$A" get "$reply_ticket" --out "$work/reply.wav" >/dev/null 2>"$work/get.log" || {
  echo "FAIL: reply blob fetch failed" >&2
  cat "$work/get.log" >&2
  exit 1
}
python3 - <<PY
import wave
w = wave.open("$work/reply.wav")
rate, ch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
frames = w.getnframes()
assert (rate, ch, width) == (24000, 1, 2), (rate, ch, width)
assert frames > 24000, "reply audio too short"  # at least 1s of audio
print(f"reply wav: {frames/24000:.1f}s @ 24kHz mono")
PY

if grep -q "gpt-live session error\|AI_GATEWAY_API_KEY" "$work/eve.log"; then
  echo "FAIL: live session error in eve log" >&2
  tail -20 "$work/eve.log" >&2
  exit 1
fi

echo "PASS: voice memo -> GPT-Live -> spoken reply (ticket $reply_ticket)"
