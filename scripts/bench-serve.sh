#!/bin/bash
# Serve the bench peer (relay/message latency + voice-turn reports) with the
# shared serve script. Same output/pairing contract as live-voice-serve.sh:
# prints the contact/ticket pairing lines, then stays in the foreground.
# Sourced (not exec'd) so the process keeps this script's name for `pnpm agent`.
export EVE_AGENT="${EVE_AGENT:-bench}"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/live-voice-serve.sh" "$@"
