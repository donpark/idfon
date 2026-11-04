#!/bin/bash
# Serve one talk-radio station: a roster entry gets its own state dir, identity
# and pinned port, so two topics share an agent directory but neither a
# schedule, a brief, nor a content cache (docs/live-radio.md).
#
#   scripts/radio-serve.sh "tech talk"
#   scripts/radio-serve.sh radio-wildlife
#   scripts/radio-serve.sh "Wildlife Hour"
#
#   scripts/radio-serve.sh "tech talk" <ios-endpoint-id>
#     Also admit one app that has its own identity (the iPhone): the holder
#     admits senders by endpoint id, and a phone's id is not in the Mac daemon's
#     peer list. Register it once, then pair the app with `-pair-ticket` (the
#     serve script prints that line).
#
# State lives in agents/radio/instances/<instance>/ (schedule.json,
# submissions.jsonl, candidates.jsonl, content/, soak.jsonl). Programme it with
# `scripts/radio-program.mjs ... --instance <instance>`.
#
# The stream backend talks to no model, so no gateway key is needed: the runner
# is built without the gpt-live feature and the key below is a placeholder that
# only satisfies scripts/live-voice-serve.sh's check.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
station="${1:-}"
ios_endpoint="${2:-}"
if [ -z "$station" ]; then
  echo "usage: radio-serve.sh <roster topic|instance|name> [ios-endpoint-id]" >&2
  exit 1
fi

# `config` creates the station state, seeds its schedule, and writes a live
# config with absolute paths; it prints instance, name, config path.
info=$(node "$root/scripts/radio-program.mjs" config "$station")
instance=$(printf '%s\n' "$info" | sed -n 1p)
name=$(printf '%s\n' "$info" | sed -n 2p)
live_config=$(printf '%s\n' "$info" | sed -n 3p)
if [ -z "$instance" ] || [ -z "$live_config" ]; then
  echo "radio-serve: could not resolve station '$station'" >&2
  exit 1
fi
echo "station: $name ($instance)" >&2

# `extra_senders` in the serve script reads capability-ticket-<endpoint>.json
# and mints a subject-bound ticket for each id, so an empty file is enough to
# register the phone. It must exist before the serve script starts.
if [ -n "$ios_endpoint" ]; then
  home="${EVE_VOICE_HOME:-$HOME/.idfon/$instance}"
  mkdir -p "$home"
  : > "$home/capability-ticket-$ios_endpoint.json"
  echo "admitting app endpoint: $ios_endpoint" >&2
fi

export EVE_AGENT="${EVE_AGENT:-llm}"
export EVE_INSTANCE="$instance"
export EVE_CONTACT_NAME="$name"
export EVE_LIVE_CONFIG="$live_config"
export EVE_IDFON_FEATURES=
# `: "${VAR:=...}"` would assign without exporting, and the child script reads
# the environment.
export AI_GATEWAY_API_KEY="${AI_GATEWAY_API_KEY:-unused-by-stream-backend}"

# Sourced (not exec'd) so the process keeps this script's name for
# `pnpm agent` process checks (the llm-serve.sh pattern).
. "$root/scripts/live-voice-serve.sh"
