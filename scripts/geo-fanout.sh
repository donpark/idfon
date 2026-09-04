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
#   REGIONS="iad1 sfo1 fra1" scripts/geo-fanout.sh TICKET 3   # geo spread
#
# Environment: SNAPSHOT_ID (built sandbox snapshot), LISTEN_SECONDS (15).

SNAPSHOT_ID="${SNAPSHOT_ID:?set SNAPSHOT_ID to a sandbox snapshot with the built listener}"
LISTEN_SECONDS="${LISTEN_SECONDS:-15}"

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
    r=$(echo "$REGIONS" | tr ',' '\n' | sed -n "$(( (i-1) % $(echo "$REGIONS" | tr ',' '\n' | wc -l) + 1 ))p")
    region="--region $r"
  fi
  name="nufon-geo-$i-$$"
  vercel sandbox create --snapshot "$SNAPSHOT_ID" --name "$name" --timeout 15m $region >/dev/null 2>&1 \
    || { echo "FAIL: sandbox $name" >&2; overall=1; continue; }
  names="$names $name"
done

out_dir=$(mktemp -d /tmp/nufon-geo-results.XXXXXX)
for name in $names; do
  vercel sandbox exec "$name" -- sh -c "cd /tmp/src && ./target/release/examples/stream-recorder '$TICKET' --seconds $LISTEN_SECONDS --out /tmp/geo-rec" \
    > "$out_dir/$name.log" 2>&1 \
    && cp "$out_dir/$name.log" "$out_dir/$name.ok" &
done
wait

echo "=== per-listener results ==="
for name in $names; do
  if [ -f "$out_dir/$name.ok" ]; then
    # pull metrics json back and summarize
    vercel sandbox copy "$name:/tmp/geo-rec.timings.json" "$out_dir/$name.timings.json" >/dev/null 2>&1
    jq -c --arg n "$name" '{listener: $n, packets: (.packets|length), startup_ms: .packets[0].t_ms}' \
      "$out_dir/$name.timings.json" 2>/dev/null
  else
    echo "listener $name: FAILED"
    overall=1
  fi
done

for name in $names; do vercel sandbox remove "$name" >/dev/null 2>&1 || true; done

[ "$overall" = 0 ] && echo "PASS: geo fan-out ($N listeners)" \
                  || { echo "FAIL: geo fan-out" >&2; exit 1; }
