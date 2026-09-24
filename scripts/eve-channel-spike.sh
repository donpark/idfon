#!/bin/sh
set -eu

# M0 acceptance for the Eve channel contract: loopback turns must create and
# resume sessions by channel-local address, and auth must reach the session.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture="$root/agents/ai-chat"
work=$(mktemp -d /tmp/eve-idfon-channel.XXXXXX)
pid=""
cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

cp -R "$fixture/." "$work/app"
cd "$work/app"
npm install --no-audit --no-fund --silent
npx eve build >"$work/build.log" 2>&1 || {
  cat "$work/build.log" >&2
  exit 1
}

port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)
reply_file="$work/replies.ndjson"
EVE_SPIKE_REPLY_FILE="$reply_file" npx eve start --host 127.0.0.1 --port "$port" >"$work/server.log" 2>&1 &
pid=$!

for _ in $(seq 1 150); do
  if curl -sS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$work/server.log" >&2
    exit 1
  fi
  sleep 0.1
done

post_turn() {
  curl -fsS -X POST "http://127.0.0.1:$port/idfon/turn" \
    -H 'content-type: application/json' \
    --data "$1"
}
wait_for_replies() {
  expected=$1
  for _ in $(seq 1 150); do
    if [ -f "$reply_file" ] && [ "$(wc -l <"$reply_file")" -ge "$expected" ]; then
      return
    fi
    sleep 0.1
  done
  echo "FAIL: timed out waiting for $expected replies" >&2
  cat "$work/server.log" >&2
  exit 1
}

first=$(post_turn '{"peerId":"peer-a","conversation":"thread-1","text":"hello"}')
wait_for_replies 1
second=$(post_turn '{"peerId":"peer-a","conversation":"thread-1","text":"again"}')
wait_for_replies 2
third=$(post_turn '{"peerId":"peer-b","conversation":"thread-1","text":"other"}')

python3 - "$reply_file" "$first" "$second" "$third" <<'PY'
import json
import sys
import time

reply_file, first_raw, second_raw, third_raw = sys.argv[1:]
responses = [json.loads(value) for value in (first_raw, second_raw, third_raw)]
assert responses[0]["address"] == "peer-a:thread-1"
assert responses[1]["address"] == responses[0]["address"]
assert responses[2]["address"] == "peer-b:thread-1"
assert responses[0]["sessionId"] == responses[1]["sessionId"]
assert responses[0]["sessionId"] != responses[2]["sessionId"]

for _ in range(150):
    try:
        with open(reply_file) as stream:
            rows = [json.loads(line) for line in stream if line.strip()]
    except FileNotFoundError:
        rows = []
    if len(rows) >= 3:
        break
    time.sleep(0.1)
else:
    raise AssertionError(f"expected 3 replies, got {len(rows)}")

expected = [
    (responses[0]["sessionId"], "reply 1: hello", "peer-a"),
    (responses[1]["sessionId"], "reply 2: again", "peer-a"),
    (responses[2]["sessionId"], "reply 1: other", "peer-b"),
]
actual = [(row["sessionId"], row["message"], row["principalId"]) for row in rows[:3]]
assert actual == expected, (actual, expected)
print("PASS: channel address/session mapping, queued turns, and session auth")
PY
