#!/bin/bash
# Serve the agency agent together with its catalog provisioner.
#
# The provisioner is the registry + policy point: targets register their own
# cards with it, and it enforces caller policy. It never signs. This script
# starts it (if not already running) and delegates to the shared serve script.
#
# Roster holders are separate `llm` instances, started once each:
#   EVE_INSTANCE=gpt61 EVE_CONTACT_NAME="GPT-6.1-Sol" \
#     EVE_IDFON_MODEL=openai/gpt-6.1-sol scripts/llm-serve.sh
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
. "$root/scripts/live-voice-serve.sh" "$@"
