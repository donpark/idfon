#!/bin/bash
# Serve the generic voice agent with a provider config — one command per tryout.
#
#   scripts/voice-serve.sh agents/voice/providers/groq.json
#   scripts/voice-serve.sh                       # default live.json
#
# The provider file is a full live config (`backend` + `voice_route` + `engine`),
# so adding an ASR/TTS service to try is a JSON file. Keys come from the env
# vars named in that file.
export EVE_AGENT="${EVE_AGENT:-voice}"
export EVE_IDFON_PKG="${EVE_IDFON_PKG:-idfon-voice-agent}"
export EVE_IDFON_BIN="${EVE_IDFON_BIN:-eve-idfon-voice}"
if [ -n "${1:-}" ] && [ -f "$1" ]; then
  export EVE_LIVE_CONFIG="$1"
  shift
fi
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/live-voice-serve.sh" "$@"
