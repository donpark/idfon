#!/bin/bash
# Serve the directory agent together with its catalog provisioner.
#
# The provisioner is the chokepoint: it owns the roster, enforces caller
# policy, and mints the subject-bound invite tickets. This script only starts
# it (if not already running) and then delegates to the shared serve script.
#
# Roster holders are separate `llm` instances, started once each:
#   EVE_INSTANCE=gpt61 EVE_CONTACT_NAME="GPT-6.1-Sol" \
#     EVE_IDFON_MODEL=openai/gpt-6.1-sol scripts/llm-serve.sh
#
# Policy env (see scripts/directory-provisioner.mjs):
#   DIRECTORY_ROSTER, DIRECTORY_PORT, DIRECTORY_SECRET, DIRECTORY_ALLOW_CALLERS
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
port="${DIRECTORY_PORT:-18777}"
secret="${DIRECTORY_SECRET:-m2-test-secret}"

if ! curl -fsS -H "x-idfon-provisioner-secret: $secret" \
  "http://127.0.0.1:$port/catalog" >/dev/null 2>&1; then
  node "$root/scripts/directory-provisioner.mjs" &
  echo $! > "${TMPDIR:-/tmp}/directory-provisioner.pid"
fi

export EVE_AGENT="${EVE_AGENT:-directory}"
export DIRECTORY_PROVISIONER_URL="${DIRECTORY_PROVISIONER_URL:-http://127.0.0.1:$port}"
export DIRECTORY_PROVISIONER_SECRET="$secret"
. "$root/scripts/live-voice-serve.sh" "$@"
