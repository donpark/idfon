#!/bin/bash
# Serve the GPT-Live-1 full-duplex agent (native-duplex; hardwired to the
# live-API backend) with the shared serve script. Sourced (not exec'd) so the
# process keeps this script's name for `pnpm agent` process checks.
export EVE_AGENT="${EVE_AGENT:-gpt-live-1}"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/live-voice-serve.sh" "$@"
