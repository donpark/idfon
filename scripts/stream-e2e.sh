#!/bin/sh
set -eu

# Live audio streaming between two endpoints over the real daemon protocol,
# driven through the nufon CLI (no microphone, no GUI):
#
#   nufond (endpoint A) -- nufon stream --file pip.wav --loop --> live ticket
#   nufond (endpoint B) -- nufon listen TICKET --out rec.wav
#
# The source is a "pip" pattern (100ms 1kHz tone every 2s), so the decoded
# recording measures the live path: pip count, decode jitter, packet-arrival
# jitter, and a pip-phase latency estimate (~±0.2s).
#
# Cases: stream via --file, and stream via stdin pipe (spooled by the CLI).

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# Build the vendored dylib first (the thin nufond links it); flags must match
# native/build.zig so the dylib's install name stays @executable_path-relative.
RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p nufond -p nufon-cli
# A relink can leave an ad-hoc signature that no longer matches the pages;
# the kernel then SIGKILLs the process at exec ("Code Signature Invalid").
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/nufond target/release/nufon

work=$(mktemp -d /tmp/nufon-live-e2e.XXXXXX)
pids=""
cleanup() {
  if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

NUF="$root/target/release/nufon"
A="$work/publisher/nufond.sock"
B="$work/listener/nufond.sock"

# Test source: 100ms @1kHz every 2s, 60s (looped by the publisher).
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

mkdir -p "$work/publisher" "$work/listener"
"$root/target/release/nufond" --socket "$A" --data-dir "$work/publisher" &
pids="$pids $!"
"$root/target/release/nufond" --socket "$B" --data-dir "$work/listener" &
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
wait_ready "$A" publisher
wait_ready "$B" listener

analyze() { # wav json label
  python3 - "$1" "$2" <<'EOF'
import sys, wave, struct, json, statistics
w = wave.open(sys.argv[1], 'rb')
assert w.getframerate() == 48000 and w.getnchannels() == 1, "expected 48k mono WAV"
frames = w.readframes(w.getnframes())
pcm = struct.unpack('<%dh' % (len(frames)//2), frames)
meta = json.load(open(sys.argv[2]))

# pip onsets: first 10ms window of each run above energy threshold
ON, OFF = 1000, 200
onsets, above = [], False
for s in range(0, len(pcm) - 480, 480):
    e = sum(abs(x) for x in pcm[s:s+480]) / 480
    if not above and e > ON:
        onsets.append(s / 48000); above = True
    elif above and e < OFF:
        above = False

intervals = [b - a for a, b in zip(onsets, onsets[1:])]
jitter_ms = statistics.stdev(intervals) * 1000 if len(intervals) > 1 else 0.0

# Latency: L = (frac(pip phase) + (R0 - P0) mod 2) mod 2, where P0/R0 are the
# publisher/listener wall-clock anchors. ~±0.2s slop from startup between
# anchor and first sample — enough to rank configurations.
assert meta['p0_wall_ms'] and meta['wall_ms'], "missing wall-clock anchors"
d = (meta['wall_ms'] - meta['p0_wall_ms']) / 1000.0
lat = statistics.median([((o % 2.0) + (d % 2.0)) % 2.0 for o in onsets])

print(f"  pips={len(onsets)} jitter={jitter_ms:.1f}ms arrival_jitter={meta['arrival_jitter_ms']}ms latency~{lat:.2f}s duration={meta['duration_ms']}ms")
print(f"  ux: startup={meta['startup_ms']}ms subscribe={meta['subscribe_ms']}ms "
      f"max_gap={meta['max_gap_ms']}ms stalls>100ms={meta['stalls_over_100ms']} "
      f"missing={meta['missing_packets']} prebuffer={meta['prebuffer_ms']}ms")
# UX gates: a fully-received stream can still stutter. Startup must be fast,
# no arrival gap may exceed a modest play buffer, the publisher timeline must
# arrive without holes, and the prebuffer needed to avoid underrun stays small.
ux_ok = (meta['startup_ms'] < 2000 and meta['max_gap_ms'] < 500
         and meta['stalls_over_100ms'] == 0 and meta['missing_packets'] == 0
         and meta['prebuffer_ms'] < 200)
ok = len(onsets) >= 5 and jitter_ms < 100 and lat < 3.0 and meta['duration_ms'] >= 10000 and ux_ok
sys.exit(0 if ok else 1)
EOF
}

run_case() { # label stream-args...
  label=$1; shift
  echo "case: $label"
  stream_json=$("$NUF" --socket "$A" stream --json "$@" > "$work/stream.json" && cat "$work/stream.json")
  ticket=$(printf '%s' "$stream_json" | jq -r .result.ticket)
  p0_wall_ms=$(printf '%s' "$stream_json" | jq -r .result.wall_ms)
  # Publisher needs a moment before its first pkarr/discovery publish lands.
  sleep 2
  "$NUF" --socket "$B" listen "$ticket" --out "$work/rec.wav" --seconds 15 --json \
    | jq --argjson p0 "$p0_wall_ms" '.result + {p0_wall_ms: $p0} | del(.out)' > "$work/listen.json"
  cat "$work/listen.json" | jq -c 'del(.p0_wall_ms)'
  analyze "$work/rec.wav" "$work/listen.json" \
    && echo "PASS: $label" \
    || { echo "FAIL: $label (analysis above)" >&2; exit 1; }
}

run_case "stream --file --loop" --file "$work/pip.wav" --loop
run_case "stream via stdin pipe" --loop < "$work/pip.wav"

echo "PASS: nufon stream/listen live audio over two daemon endpoints"
