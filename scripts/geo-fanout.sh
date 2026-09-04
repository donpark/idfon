#!/bin/sh
set -eu

# True fan-out over the real internet using Vercel Sandboxes as listeners.
#
# One local publisher (nufon stream), N cloud listeners (one sandbox each,
# forked from a prebuilt snapshot holding the Linux stream-recorder binary).
# Each listener captures the stream and reports the playback-UX metrics;
# results are aggregated locally.
#
# Requirements:
#   - vercel CLI authenticated; the snapshot must contain the built
#     stream-recorder binary at /tmp/src/target/release/examples/
#   - a local publisher started separately (relays ON, so cloud listeners
#     can rendezvous through n0's public relays and hole-punch)
#
# Usage:
#   scripts/geo-fanout.sh TICKET [N]     # N listeners, default 3, region iad1
#   REGIONS="iad1,sfo1,fra1" scripts/geo-fanout.sh TICKET 3   # geo spread (space or comma separated)
#
# Environment: SNAPSHOT_ID (built sandbox snapshot), LISTEN_SECONDS (15),
#   WAVES (concurrent-launch batch size; launches proceed in waves of this
#   many sandboxes, default 8), EXEC_TIMEOUT (per-exec cap, default 180s).
# A wedged exec is killed at EXEC_TIMEOUT and its listener counted as
# failed, instead of stalling the whole run.

SNAPSHOT_ID="${SNAPSHOT_ID:?set SNAPSHOT_ID to a sandbox snapshot with the built listener}"
LISTEN_SECONDS="${LISTEN_SECONDS:-15}"
WAVES="${WAVES:-8}"
EXEC_TIMEOUT="${EXEC_TIMEOUT:-180}"

run_exec() { # name ticket — exec listener with a hard local timeout
  local name=$1 ticket=$2
  perl -e 'alarm shift; exec @ARGV' "$EXEC_TIMEOUT" \
    vercel sandbox exec "$name" -- sh -c "cd /tmp/src && ./target/release/examples/stream-recorder '$ticket' --seconds $LISTEN_SECONDS --out /tmp/geo-rec"
}

TICKET=$1
N=${2:-3}
REGIONS=${REGIONS:-}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

names=""
overall=0
for i in $(seq 1 "$N"); do
  region=""
  if [ -n "$REGIONS" ]; then
    r=$(echo "$REGIONS" | tr ' ,' '\n\n' | grep -v '^$' | sed -n "$(( (i-1) % $(echo "$REGIONS" | tr ' ,' '\n\n' | grep -cv '^$') + 1 ))p")
    region="--region $r"
  fi
  name="nufon-geo-$i-$$"
  vercel sandbox create --snapshot "$SNAPSHOT_ID" --name "$name" --timeout 15m $region > /tmp/geo-create.log 2>&1 \
    || { echo "FAIL: sandbox $name"; tail -3 /tmp/geo-create.log >&2; overall=1; continue; }
  names="$names $name"
done

out_dir=$(mktemp -d /tmp/nufon-geo-results.XXXXXX)
for name in $names; do
  run_exec "$name" "$TICKET" > "$out_dir/$name.log" 2>&1 \
    && cp "$out_dir/$name.log" "$out_dir/$name.ok" &
done
wait

echo "=== per-listener results ==="
for name in $names; do
  if [ -f "$out_dir/$name.ok" ]; then
    vercel sandbox copy "$name:/tmp/geo-rec.timings.json" "$out_dir/$name.timings.json" >/dev/null 2>&1
    python3 - "$name" "$out_dir/$name.timings.json" <<'EOF'
import sys, json, statistics
name, path = sys.argv[1], sys.argv[2]
meta = json.load(open(path))
arr = [p['t_ms'] for p in meta['packets']]
pts = [p['pts_ms'] for p in meta['packets']]
gaps = [b-a for a, b in zip(arr, arr[1:])]
jitter = statistics.stdev(gaps) if len(gaps) > 1 else 0.0
a0, p0 = arr[0], pts[0]
prebuffer = max((a - (a0 + (p - p0))) for a, p in zip(arr, pts))
step = statistics.median(pts[i+1]-pts[i] for i in range(len(pts)-1))
missing = sum(round((pts[i+1]-pts[i])/step)-1 for i in range(len(pts)-1)
              if pts[i+1] > pts[i] + 1.5*step)
stalls = sum(g > 100 for g in gaps)
print(json.dumps({'listener': name, 'packets': len(arr), 'startup_ms': arr[0],
    'arrival_jitter_ms': round(jitter, 1), 'max_gap_ms': max(gaps),
    'stalls_over_100ms': stalls, 'missing_packets': missing,
    'prebuffer_ms': prebuffer}))
EOF
  else
    echo "listener $name: FAILED"
    overall=1
  fi
done

for name in $names; do vercel sandbox remove "$name" >/dev/null 2>&1 || true; done

[ "$overall" = 0 ] && echo "PASS: geo fan-out ($N listeners)" \
                  || { echo "FAIL: geo fan-out" >&2; exit 1; }
