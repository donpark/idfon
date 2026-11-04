#!/bin/bash
# The radio-world agent as one unit (docs/live-radio.md "The radio-world
# agent"): the OPML menu contact whose menu and programming are handled
# internally — `pnpm agent start radio-world` is the whole recipe. Sourced
# (not exec'd) into the shared serve script so the process keeps this
# script's name for `pnpm agent` process checks.
#
#   scripts/radio-world-serve.sh [ios-endpoint-id]
#
# Internals it owns so nobody pieces them together:
#   - the station menu (agents/radio-world/shows.opml): curated from Radio
#     Browser when missing (scripts/radio-stations-opml.mjs); the committed
#     file keeps an offline start working.
#   - the instance state (agents/radio/instances/radio-world/, ~/.idfon/
#     radio-world): written by scripts/radio-program.mjs config, with `opml`
#     pointing at the menu so the contact's detail surface and the agent's
#     json-render menu (IDFON_RADIO_MENU) agree.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export EVE_AGENT="${EVE_AGENT:-radio-world}"
export EVE_INSTANCE="${EVE_INSTANCE:-radio-world}"
export IDFON_RADIO_ROOT="$root"
export IDFON_RADIO_INSTANCE="${IDFON_RADIO_INSTANCE:-radio-world}"

menu="$root/agents/radio-world/shows.opml"
if [ ! -s "$menu" ]; then
  echo "radio-world: curating the station menu (Radio Browser)…" >&2
  node "$root/scripts/radio-stations-opml.mjs" --out "$menu" >&2 \
    || echo "radio-world: curation failed; start again when online (shows.opml is empty)" >&2
fi
export IDFON_RADIO_MENU="$menu"

# The unit's identity (agents/radio-world/live.json) over the generated
# instance config, which supplies the absolute state paths the holder needs;
# `opml` points at the menu so the contact's detail surface and the agent's
# json-render menu (IDFON_RADIO_MENU) agree.
node "$root/scripts/radio-program.mjs" config radio-world >/dev/null
live_config="$root/agents/radio/instances/radio-world/live.json"
tmp=$(mktemp)
jq --slurpfile unit "$root/agents/radio-world/live.json" --arg opml "$menu" \
  '. * $unit[0] | .opml = $opml' "$live_config" >"$tmp" && mv "$tmp" "$live_config"
export EVE_LIVE_CONFIG="$live_config"

. "$root/scripts/radio-serve.sh" radio-world "$@"
