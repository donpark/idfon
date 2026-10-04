#!/bin/bash
# Serve the cascade-voice demo: a text agent whose voice is delivered by the
# client-side (A1) cascade — on-device STT/TTS in the app — over the cascade
# holder composition root. Contrast scripts/live-voice-serve.sh, which serves
# the native-duplex GPT-Live demo.
#
# Same output/pairing contract as live-voice-serve.sh; this wrapper only picks
# the agent and the holder binary. Sourced (not exec'd) so the process keeps
# this script's name for `pnpm agent` process checks.
export EVE_AGENT="${EVE_AGENT:-cascade-voice}"
export EVE_IDFON_PKG="${EVE_IDFON_PKG:-idfon-voice-agent}"
export EVE_IDFON_BIN="${EVE_IDFON_BIN:-eve-idfon-voice}"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/live-voice-serve.sh" "$@"
