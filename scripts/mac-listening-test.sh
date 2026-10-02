#!/bin/sh
set -eu

# P7 listening test (objective half): synthesize a phrase set with the default
# on-device voice and transcribe it back on device, then score word error rate
# against the PassBar. The subjective HF/quality judgement is still a human call
# (the Apple OS voice is full-band, so BWE is not expected).
#
#   scripts/mac-listening-test.sh [--no-build]

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
build=1
[ "${1:-}" = "--no-build" ] && build=0

if [ "$build" = 1 ]; then
  mac/build.sh >/dev/null
fi
app="$root/mac/build/Idfon.app/Contents/MacOS/Idfon"
[ -x "$app" ] || { echo "no built app at $app" >&2; exit 2; }

log=$(mktemp /tmp/idfon-mac-listening.XXXXXX)
echo "running listening test; log=$log"
"$app" -voicelistening >"$log" 2>&1 &
pid=$!
for _ in $(seq 1 60); do
  grep -q 'idfon-auto: voice: listening done' "$log" 2>/dev/null && break
  sleep 1
done
kill "$pid" 2>/dev/null || true

# Only the stderr markers (no timestamped NSLog duplicate).
grep -a '^idfon-auto: voice: listening pair' "$log" >"$log.pairs"
[ -s "$log.pairs" ] || { echo "FAIL: no pairs captured" >&2; cat "$log" >&2; exit 1; }

python3 - "$log.pairs" <<'PY'
import re
import sys

def wer(ref, hyp):
    ref = ref.lower().split()
    hyp = hyp.lower().split()
    d = [[0] * (len(hyp) + 1) for _ in range(len(ref) + 1)]
    for i in range(len(ref) + 1):
        d[i][0] = i
    for j in range(len(hyp) + 1):
        d[0][j] = j
    for i in range(1, len(ref) + 1):
        for j in range(1, len(hyp) + 1):
            d[i][j] = min(
                d[i - 1][j] + 1,
                d[i][j - 1] + 1,
                d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]),
            )
    return d[len(ref)][len(hyp)] / max(1, len(ref))

total = 0.0
count = 0
for line in open(sys.argv[1]):
    match = re.search(r"ref=(.*) hyp=(.*)$", line.strip())
    if not match:
        continue
    ref, hyp = match.group(1), match.group(2)
    if hyp == "FAILED":
        print(f"  FAILED: {ref}")
        count += 1
        total += 1.0
        continue
    score = wer(ref, hyp)
    total += score
    count += 1
    print(f"  wer={score:.2f} ref={ref!r} hyp={hyp!r}")

accuracy = 1 - (total / max(1, count))
bar = 0.95
print(f"pairs={count} mean_wer={total / max(1, count):.3f} intelligibility={accuracy:.3f} bar={bar}")
if accuracy >= bar:
    print("PASS: listening test (objective intelligibility)")
else:
    print("FAIL: listening test below PassBar")
    sys.exit(1)
PY
