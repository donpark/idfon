#!/bin/sh
# GEPA on the voice-prompt lab: optimize a voice prompt against a labelled
# corpus, without a human in the loop.
#
# Each generation: rewrite the current best prompt from the turns it failed
# (reflective mutation, `voice-gepa-mutate.py`), score every rewrite with the
# real lab over the corpus, keep the best, repeat. The corpus is the objective —
# a corpus of real calls beats one written from rules, so grow
# `agents/<agent>/turns.jsonl` from calls and re-run.
#
#   scripts/voice-gepa.sh                          # 2 generations x 3 variants
#   scripts/voice-gepa.sh --generations 3 --variants 4
#   scripts/voice-gepa.sh --corpus agents/llm/turns.jsonl --out /tmp/live.json
#   scripts/voice-gepa.sh --selftest               # offline: fake lab + mutator
#
#   --agent NAME       agent under agents/ (default llm), for the defaults below
#   --corpus FILE      labelled turns (default agents/<agent>/turns.jsonl)
#   --seed FILE        live config to optimize (default agents/<agent>/live.json)
#   --out FILE         where to write the winner
#                      (default agents/<agent>/live.optimized.json)
#   --generations N    mutation rounds (default 2)
#   --variants N       rewrites per round (default 3)
#   --model ID         model for the rewrites (default $GEPA_MODEL or the lab's)
#   --keep             keep the temporary work tree
#   --selftest         run the loop against a fake lab and mutator: no key, no
#                      network, no spend
#
# Environment: AI_GATEWAY_API_KEY (the mutator's model, and the agent's, when the
# lab runs for real). GEPA_LAB / GEPA_MUTATOR override the two pieces, which is
# what --selftest uses.
#
# Cost: one lab run per round, and a round is one variant per config. Each lab
# run starts the whole stack and sends the corpus, so a round is seconds per
# variant plus a few cents of model calls.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

agent=llm
corpus=""
seed=""
out=""
generations=2
variant_count=3
model="${GEPA_MODEL:-}"
keep=0
selftest=0

usage() { sed -n '2,30p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) agent="$2"; shift 2 ;;
    --corpus) corpus="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --generations) generations="$2"; shift 2 ;;
    --variants) variant_count="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --keep) keep=1; shift ;;
    --selftest) selftest=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$corpus" ] || corpus="agents/$agent/turns.jsonl"
[ -n "$seed" ] || seed="agents/$agent/live.json"
[ -n "$out" ] || out="agents/$agent/live.optimized.json"
[ -f "$corpus" ] || { echo "no corpus: $corpus" >&2; exit 2; }
[ -f "$seed" ] || { echo "no seed config: $seed" >&2; exit 2; }

lab="${GEPA_LAB:-$root/scripts/voice-prompt-lab.sh}"
mutator="${GEPA_MUTATOR:-$root/scripts/voice-gepa-mutate.py}"
# The mutator needs the gateway; without an override, say so before spending a
# lab run finding out.
if [ "$selftest" != 1 ] && [ -z "${GEPA_MUTATOR:-}" ] && [ -z "${AI_GATEWAY_API_KEY:-}" ]; then
  echo "AI_GATEWAY_API_KEY is not set (the mutator and the lab both need it)" >&2
  exit 2
fi

work=$(mktemp -d /tmp/idfon-gepa.XXXXXX)
cleanup() { [ "$keep" = 1 ] || rm -rf "$work"; }
trap cleanup EXIT INT TERM

# Score every config in a directory over the corpus.
#   $1 dir  $2 report path (JSONL)  $3 lab log path
# Prints the per-config means as JSON, best first.
score_dir() {
  : >"$2"
  if ! "$lab" --variants "$1" --turns "$corpus" --json-out "$2" >"$3" 2>&1; then
    echo "lab failed; log: $3" >&2
    tail -20 "$3" >&2
    exit 1
  fi
  jq -s 'group_by(.config)
         | map({config: .[0].config, mean: ([.[].score] | add / length),
                passed: ([.[].score] | add), turns: length})
         | sort_by(-.mean, -.passed)' "$2"
}

# The failed turns of one config, as the mutator's feedback.
#   $1 report path  $2 config path
failures_of() {
  jq -c -s --arg config "$2" \
    '[.[] | select(.config == $config and .score == 0)
      | {text, reply, expect, forbid}]' "$1"
}

# Ask the mutator for rewrites of the instructions in $1, for the failures in $2.
#   $3 = variants JSON path
mutate() {
  jq -cn --arg instructions "$1" --arg model "$model" \
    --argjson count "$variant_count" --argjson failures "$2" \
    '{instructions: $instructions, model: $model, count: $count, failures: $failures}' \
    | "$mutator" >"$3"
  jq -e '.variants | length > 0' "$3" >/dev/null 2>&1 \
    || { echo "mutator produced no variants: $3" >&2; exit 1; }
}

# Write each variant as a full live config (the seed with its instructions
# replaced), so the lab can serve it unchanged.
#   $1 variants JSON path  $2 output dir
write_variants() {
  mkdir -p "$2"
  jq -c '.variants[]' "$1" | while IFS= read -r variant; do
    name=$(printf '%s' "$variant" | jq -r '.name' | sed 's/[^A-Za-z0-9._-]/-/g')
    ins=$(printf '%s' "$variant" | jq -r '.instructions')
    jq --arg instructions "$ins" --arg seed "$seed" --arg model "$model" \
      '.instructions = $instructions
       | ._gepa = {from: "voice-gepa", seed: $seed, model: $model}' \
      "$seed" >"$2/$name.json"
  done
}

# --- selftest: the loop's own logic, offline -------------------------------

if [ "$selftest" = 1 ]; then
  fake="$work/fake"
  mkdir -p "$fake"
  # Never write over a real optimized config from a selftest.
  out="$work/live.optimized.json"
  cat >"$fake/lab" <<'FAKELAB'
#!/bin/sh
# Fake lab: scores each config 1 when its instructions say BETTER.
dir=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --variants) dir="$2"; shift 2 ;;
    --json-out) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
: >"$out"
for f in "$dir"/*.json; do
  [ -e "$f" ] || continue
  case "$(jq -r .instructions "$f")" in
    *BETTER*) score=1 ;;
    *) score=0 ;;
  esac
  jq -cn --arg config "$f" --argjson score "$score" \
    '{config: $config, text: "hello", reply: "r", expect: "", forbid: [], score: $score}' >>"$out"
  echo "score: $score/1"
done
FAKELAB
  cat >"$fake/mutator" <<FAKEMUTATOR
#!/bin/sh
# Fake mutator: one rewrite that fixes the failure, one that does not. Records
# what it was asked, so the feedback wiring is checked too.
cat >>"$work/selftest.requests.jsonl"
printf '%s' '{"variants":[{"name":"better","instructions":"BETTER: answer directly in plain speech."},{"name":"same","instructions":"SAME: nothing changed."}]}'
FAKEMUTATOR
  chmod +x "$fake/lab" "$fake/mutator"
  lab="$fake/lab"
  mutator="$fake/mutator"
fi

# --- the loop --------------------------------------------------------------

summary="$work/summary.tsv"
# The seed is scored as a config file like any other, and the report records the
# path it was scored from — so that same path must be the one fed back.
seed_dir="$work/seed-scores"
mkdir -p "$seed_dir"
cp "$seed" "$seed_dir/seed.json"
best_config="$seed_dir/seed.json"

seed_report="$work/seed.jsonl"
score_dir "$seed_dir" "$seed_report" "$work/seed.log" >"$work/seed.means.json"
best_mean=$(jq -r '.[0].mean' "$work/seed.means.json")
best_report="$seed_report"
printf '%s\t%s\t%s\n' 0 seed "$best_mean" >"$summary"
echo "generation 0 (seed): mean $best_mean"

round=1
while [ "$round" -le "$generations" ]; do
  gen="$work/gen$round"
  mutate "$(jq -r '.instructions' "$best_config")" "$(failures_of "$best_report" "$best_config")" "$gen-variants.json"
  write_variants "$gen-variants.json" "$gen"
  gen_report="$work/gen$round.jsonl"
  means=$(score_dir "$gen" "$gen_report" "$work/gen$round.log")
  echo "$means" | jq -r '.[] | "  \(.config | split("/") | last): \(.mean) (\(.passed)/\(.turns))"'
  top_mean=$(echo "$means" | jq -r '.[0].mean')
  top_config=$(echo "$means" | jq -r '.[0].config')
  printf '%s\t%s\t%s\n' "$round" "$(basename "$top_config")" "$top_mean" >>"$summary"
  echo "generation $round: best $(basename "$top_config") at $top_mean"
  if awk -v a="$best_mean" -v b="$top_mean" 'BEGIN { exit !(b > a) }'; then
    previous="$best_mean"
    best_mean="$top_mean"
    best_config="$top_config"
    best_report="$gen_report"
    echo "  kept it (was $previous)"
  fi
  round=$((round + 1))
done

mkdir -p "$(dirname "$out")"
cp "$best_config" "$out"

echo
echo "=== generations ==="
awk -F'\t' 'BEGIN { printf "%-6s %-24s %s\n", "round", "config", "mean" }
            { printf "%-6s %-24s %s\n", $1, $2, $3 }' "$summary"
echo "winner: $out (mean $best_mean)"
echo
echo "=== instructions ==="
jq -r '.instructions' "$seed" >"$work/seed.instructions"
jq -r '.instructions' "$out" >"$work/best.instructions"
diff "$work/seed.instructions" "$work/best.instructions" || true

if [ "$selftest" = 1 ]; then
  # The loop is only worth trusting if the pieces it wires together held.
  fails=$(grep -c 'hello' "$work/selftest.requests.jsonl" 2>/dev/null || true)
  case "$(jq -r '.instructions' "$out")" in
    *BETTER*) ;;
    *) echo "SELFTEST FAIL: the winner is not the better variant" >&2; exit 1 ;;
  esac
  [ "$(wc -l <"$summary" | tr -d ' ')" = "$((generations + 1))" ] \
    || { echo "SELFTEST FAIL: expected one summary row per generation" >&2; exit 1; }
  # The first generation must have been told what failed, even though the best
  # variant has nothing left to fix.
  jq -e -s 'map(.failures | length) | add > 0' "$work/selftest.requests.jsonl" >/dev/null \
    || { echo "SELFTEST FAIL: the mutator got no failure feedback" >&2; exit 1; }
  [ "$fails" -ge 1 ] || { echo "SELFTEST FAIL: feedback lost the failed turn" >&2; exit 1; }
  echo "SELFTEST OK"
fi
