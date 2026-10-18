#!/bin/bash
# Run the TYGER relay against a served voice agent's bridge (docs/voice-tyger.md, P0a).
#
# The voice agent must be serving with the relay backend
# (`EVE_LIVE_CONFIG=agents/voice/tyger.json scripts/voice-serve.sh`);
# that script writes the bridge URL to $home/bridge-url, which we read here.
# A tyger-s2s stack must be up (their run.sh, or the Docker image); its address
# and knobs are env vars — see integrations/eve-idfon-voice/tyger-relay.mjs.
#
#   TYGER_URL=ws://127.0.0.1:7860/ws scripts/tyger-live-relay.sh
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
instance="${EVE_INSTANCE:-voice}"
home="${EVE_VOICE_HOME:-$HOME/.idfon/$instance}"

if [ -z "${IDFON_BRIDGE_URL:-}" ]; then
  if [ -s "$home/bridge-url" ]; then
    IDFON_BRIDGE_URL=$(cat "$home/bridge-url")
  else
    echo "set IDFON_BRIDGE_URL, or start the voice agent first ($home/bridge-url missing)" >&2
    exit 1
  fi
fi
export IDFON_BRIDGE_URL

exec node "$root/integrations/eve-idfon-voice/tyger-relay.mjs"
