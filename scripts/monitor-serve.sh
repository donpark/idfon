#!/bin/bash
# Serve the diag monitor with the shared serve script. The monitor is a plain
# filer (docs/diag.md): it runs a mock model, so no AI gateway key is used and
# the gpt-live holder feature is not linked. Reports land in
# ~/.idfon/<instance>/diag/<device>.jsonl.
export EVE_AGENT="${EVE_AGENT:-monitor}"
export AI_GATEWAY_API_KEY="${AI_GATEWAY_API_KEY:-unused-by-monitor}"
export EVE_IDFON_MODEL="${EVE_IDFON_MODEL:-monitor}"
export EVE_IDFON_PKG="${EVE_IDFON_PKG:-eve-idfon}"
export EVE_IDFON_BIN="${EVE_IDFON_BIN:-eve-idfon}"
export EVE_IDFON_FEATURES="${EVE_IDFON_FEATURES:-}"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/live-voice-serve.sh" "$@"
