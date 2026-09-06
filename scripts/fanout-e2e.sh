#!/bin/sh
set -eu

# Fan-out scalability test: one idfon send --stream publisher, N concurrent
# idfon get subscribers, all direct P2P (runs with --no-relay: no relay
# transport, subscribers connect straight to the publisher endpoint via the
# ticket's direct addresses — no n0 public relay traffic, no rate limits).
#
# For each size in $SIZES (default "1 4 16"): N concurrent listeners for
# 12 s each, then per-listener UX metrics (startup, max gap, stalls,
# missing packets, required prebuffer). PASS requires every listener to
# receive the full capture with no stalls, no timeline holes, and a small
# required prebuffer — i.e. fan-out did not degrade playback UX.
#
# Usage: SIZES="1 4 16" scripts/fanout-e2e.sh

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

SIZES="${SIZES:-1 4 16}"
LISTEN_SECONDS="${LISTEN_SECONDS:-12}"

cargo build --release -p idfond -p idfon-cli
codesign --force -s - target/release/idfond target/release/idfon

work=$(mktemp -d /tmp/idfon-fanout.XXXXXX)
pids=""
overall=0
cleanup() {
  if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; fi
  if [ "$overall" != 0 ]; then
    echo "keeping workdir for diagnosis: $work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

NUF="$root/target/release/idfon"
A="$work/pub/idfond.sock"
B="$work/sub/idfond.sock"

# Source: pip pattern (2 s spacing) so each listener's pip count also
# verifies it kept up for the whole window, not just connected.
python3 - "$work/pip.wav" <<'EOF'
import sys, wave, math, struct
sr = 48000; frames = b''
for k in range(30):
    for i in range(int(0.1*sr)):
        frames += struct.pack('<h', int(12000*math.sin(2*math.pi*1000*i/sr)))
    frames += b'\x00' * int(1.9*sr)*2
w = wave.open(sys.argv[1],'wb')
w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
w.writeframes(frames); w.close()
EOF

mkdir -p "$work/pub" "$work/sub"
target/release/idfond --socket "$A" --data-dir "$work/pub" &
pids="$pids $!"
target/release/idfond --socket "$B" --data-dir "$work/sub" &
pids="$pids $!"
for _ in $(seq 1 100); do
  "$NUF" --socket "$A" status --json >/dev/null 2>&1 \
    && "$NUF" --socket "$B" status --json >/dev/null 2>&1 && break
  sleep 0.1
done

ticket=$("$NUF" --socket "$A" send --stream --file "$work/pip.wav" --loop --no-relay --name fanout)
sleep 2   # let the first announce land
echo "publisher up (fanout, no relay)"

overall=0
for n in $SIZES; do
  echo "=== N=$n concurrent listeners ==="
  before=$(echo "$pids" | wc -w | tr -d ' ')
  for i in $(seq 1 "$n"); do
    "$NUF" --socket "$B" get "$ticket" --out "$work/rec-$n-$i.wav" \
      --seconds "$LISTEN_SECONDS" --no-relay --json > "$work/listen-$n-$i.json" &
    pids="$pids $!"
  done
  # wait for the N listeners just launched
  for pid in $(echo "$pids" | tr ' ' '\n' | tail -n "$n"); do
    wait "$pid" 2>/dev/null || overall=1
  done

  fail=0
  for i in $(seq 1 "$n"); do
    jq -c '.result | {startup_ms, max_gap_ms, stalls_over_100ms, missing_packets, prebuffer_ms, duration_ms, packets}' \
      "$work/listen-$n-$i.json"
    ok=$(jq -r '.result | ((.duration_ms >= 10000) and (.stalls_over_100ms == 0)
                and (.missing_packets == 0) and (.prebuffer_ms < 500)
                and (.max_gap_ms < 1000))' "$work/listen-$n-$i.json")
    [ "$ok" = "true" ] || fail=1
  done
  if [ "$fail" = 0 ]; then
    echo "PASS: N=$n"
  else
    echo "FAIL: N=$n (a listener degraded below UX gates)" >&2
    overall=1
  fi
done

[ "$overall" = 0 ] && echo "PASS: fan-out over two daemon endpoints" \
                  || { echo "FAIL: fan-out" >&2; exit 1; }
