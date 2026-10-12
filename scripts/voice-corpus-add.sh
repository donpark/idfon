#!/bin/sh
# Add one labelled turn to a voice corpus (docs/voice-prompt-lab.md, #44).
#
# The corpus is the objective a prompt optimizer scores against, so it is worth
# more than the prompts: a turn that really happened and really failed is worth
# more than one written from a rule. This makes promoting one a single command
# after a call or a lab run, instead of hand-editing JSON.
#
#   scripts/voice-corpus-add.sh --text "what's the weather in Tokyo?" \
#     --forbid forward --forbid "pass along" --note "observed 2026-10-11, first call"
#
#   --corpus FILE     corpus to append to (default agents/llm/turns.jsonl)
#   --text TEXT       what the caller said (required); also the duplicate key
#   --expect TEXT     a substring the reply must contain (repeatable)
#   --forbid TEXT     a substring the reply must not contain (repeatable)
#   --note TEXT       provenance comment written above the line (repeatable)
#   --dry-run         print the line, write nothing
#
# Prints the line it appended, or says why it did not.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

corpus="agents/llm/turns.jsonl"
text=""
expect=""
forbid=""
note=""
dry=0

usage() { sed -n '2,20p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --corpus) corpus="$2"; shift 2 ;;
    --text) text="$2"; shift 2 ;;
    --expect) expect="$expect$2
"; shift 2 ;;
    --forbid) forbid="$forbid$2
"; shift 2 ;;
    --note) note="$note$2
"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$text" ] || { echo "--text is required (the caller's turn)" >&2; exit 2; }
[ -f "$corpus" ] || { echo "no such corpus: $corpus" >&2; exit 2; }

# An unlabelled turn would be printed but never scored, so it changes nothing.
if [ -z "$(printf '%s' "$expect" | tr -d '[:space:]')" ] \
  && [ -z "$(printf '%s' "$forbid" | tr -d '[:space:]')" ]; then
  echo "add --expect or --forbid: an unlabelled turn cannot fail, so it cannot teach anything" >&2
  exit 2
fi

# The JSON line. `-c` so one turn is one line, and jq escapes the text.
line=$(jq -cn \
  --arg text "$text" \
  --arg expect "$expect" \
  --arg forbid "$forbid" \
  '{text: $text}
   + (if ($expect | length) > 0 then {expect: ($expect | split("\n") | map(select(length > 0)) | first)} else {} end)
   + (if ($forbid | length) > 0 then {forbid: ($forbid | split("\n") | map(select(length > 0)))} else {} end)')

# Promotions happen after a failure, often twice. Same turn, same answer: skip.
# (Compared as JSON, not as text: jq writes `"text":"x"` and the hand-written
# lines write `"text": "x"`, so a grep for either shape misses the other.)
if python3 - "$corpus" "$text" <<'PY'
import json, sys
want = sys.argv[2]
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("{"):
        continue  # a comment, or something a hand-edit left behind
    try:
        if json.loads(line).get("text") == want:
            sys.exit(0)
    except ValueError:
        continue
sys.exit(1)
PY
then
  echo "already in $corpus: $text"
  exit 0
fi

if [ "$dry" = 1 ]; then
  printf '%s\n' "$line"
  exit 0
fi

if [ -n "$note" ]; then
  printf '%s' "$note" | while IFS= read -r one; do
    [ -n "$one" ] && printf '# %s\n' "$one" >>"$corpus"
  done
fi
printf '%s\n' "$line" >>"$corpus"
echo "added to $corpus:"
printf '%s\n' "$line"

# A corpus that does not parse is worse than a smaller one: the lab reads it line
# by line, and one bad hand-edit would make every later turn unreachable.
python3 - "$corpus" <<'PY'
import json, sys
bad = []
for n, line in enumerate(open(sys.argv[1]), 1):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    try:
        assert "text" in json.loads(line)
    except Exception as error:
        bad.append(f"{n}: {error}")
if bad:
    print("corpus is malformed:", "; ".join(bad), file=sys.stderr)
    sys.exit(1)
print("corpus parses")
PY
