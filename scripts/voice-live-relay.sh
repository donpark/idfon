#!/bin/bash
# Run the standalone TS voice relay against a served voice agent's bridge.
#
# The voice agent must be serving with the relay backend
# (`EVE_LIVE_CONFIG=agents/voice/relay.json scripts/voice-serve.sh`);
# that script writes the bridge URL to $home/bridge-url, which we read here.
#
#   scripts/voice-live-relay.sh
#
# Engine/wrap config comes from IDFON_VOICE_ENGINE (see docs/voice-agent.md).
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

exec node "$root/integrations/eve-idfon-voice/live-relay.mjs"
