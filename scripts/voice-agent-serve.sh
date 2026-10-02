#!/bin/bash
# Serve the text-only voice-agent (A1 cascade) with the shared serve script.
# Same output/pairing contract as ai-voice-chat-serve.sh. Sourced (not exec'd)
# so the process keeps this script's name for `pnpm agent` process checks.
export EVE_AGENT="${EVE_AGENT:-voice-agent}"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/ai-voice-chat-serve.sh" "$@"
