#!/bin/bash
# Serve the agency agent together with its catalog provisioner.
#
# The provisioner is the registry + policy point: targets register their own
# cards with it, and it enforces caller policy. It never signs. This script
# starts it (if not already running) and delegates to the shared serve script.
#
# Roster holders are separate `llm` instances, started once each:
#   EVE_INSTANCE=gpt61 EVE_CONTACT_NAME="GPT-6.1-Sol" \
#     EVE_IDFON_MODEL=openai/gpt-6.1-sol scripts/llm-cascade-serve.sh
#
# Policy env (see scripts/agency-provisioner.mjs):
#   AGENCY_ROSTER, AGENCY_PORT, AGENCY_SECRET, AGENCY_ALLOW_CALLERS
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
port="${AGENCY_PORT:-18777}"
secret="${AGENCY_SECRET:-m2-test-secret}"

if ! curl -fsS -H "x-idfon-provisioner-secret: $secret" \
  "http://127.0.0.1:$port/catalog" >/dev/null 2>&1; then
  node "$root/scripts/agency-provisioner.mjs" &
  echo $! > "${TMPDIR:-/tmp}/agency-provisioner.pid"
fi

export EVE_AGENT="${EVE_AGENT:-agency}"
export AGENCY_PROVISIONER_URL="${AGENCY_PROVISIONER_URL:-http://127.0.0.1:$port}"
export AGENCY_PROVISIONER_SECRET="$secret"

# Optional voice delegate: advertise that a *call* to the Agency routes to a
# voice agent (`voice_route.mode = delegated`) while text stays on the Agency.
# The delegate's peer id + endpoint address come from the operator (the voice
# agent prints them at startup). Tickets minted while this is set carry the
# route, so re-pair callers to pick it up.
if [ -n "${AGENCY_VOICE_DELEGATE:-}" ]; then
  delegate_config="${AGENCY_VOICE_DELEGATE_CONFIG:-$HOME/.idfon/agency/voice-delegate.json}"
  mkdir -p "$(dirname "$delegate_config")"
  # AGENCY_VOICE_DELEGATE_ALLOW_FILE (optional): the delegate holder's
  # allow-file; each caller minted here is admitted there so its call dials.
  jq -nc --arg peer "$AGENCY_VOICE_DELEGATE" \
    --argjson contact "${AGENCY_VOICE_DELEGATE_CONTACT:-null}" \
    --arg allow "${AGENCY_VOICE_DELEGATE_ALLOW_FILE:-}" \
    '({voice_route:{mode:"delegated",delegate:{peer_id:$peer,contact:$contact,audio:"pcm24k"}}})
     + (if $allow == "" then {} else {voice_delegate_allow_file:$allow} end)' \
    > "$delegate_config"
  export EVE_LIVE_CONFIG="$delegate_config"
fi

. "$root/scripts/live-voice-serve.sh" "$@"
