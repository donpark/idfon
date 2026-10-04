#!/bin/bash
# Serve the text-only llm (A1 cascade) with the shared serve script.
# Same output/pairing contract as live-voice-serve.sh. Sourced (not exec'd)
# so the process keeps this script's name for `pnpm agent` process checks.
export EVE_AGENT="${EVE_AGENT:-llm-cascade}"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/live-voice-serve.sh" "$@"
