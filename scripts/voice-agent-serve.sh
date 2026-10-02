#!/bin/bash
# Serve the text-only voice-agent (A1 cascade) with the shared serve script.
# Same output/pairing contract as ai-voice-chat-serve.sh.
exec env EVE_AGENT="${EVE_AGENT:-voice-agent}" \
  "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/ai-voice-chat-serve.sh" "$@"
