#!/usr/bin/env bash
# Tear down local E2E residue (#54): stray test daemons and their scratch.
# Kills only daemons on scratch profiles (--data-dir under /tmp/idfon*), never
# the app daemon (its profile lives in Application Support). The test edge and
# the apps' edge config stay — they are the live rig for the pending CallKit
# legs; the manual steps for those are docs/edge-deploy-checklist.md §B.
set -euo pipefail

# Stray daemons: scratch profiles only (includes /tmp/idfon-e2e.* from
# scripts/test-e2e.sh and the /tmp/idfon-dbg.* debug sessions).
ps -axo pid=,command= | grep '[i]dfond ' | grep -- '--data-dir /tmp/idfon' |
  while read -r pid _; do
    echo "e2e-teardown: killing stray idfond pid=$pid"
    kill "$pid" 2>/dev/null || true
  done || true   # no matches: grep exits 1 and must not abort the script

echo "e2e-teardown: removing scratch dirs and logs"
rm -rf /tmp/idfon-e2e.* /tmp/idfon-dbg.* /tmp/phone-console*.log /tmp/ring-ticket.json

# Scratch logs, probe/run files and 30s session dirs from past sessions.
# Keepers: the live pairing profile (/tmp/idfon), the app daemon's owner
# socket + log, and any backup someone made.
for f in /tmp/idfon-* /tmp/idfond-*; do
    case "$f" in
        /tmp/idfon-owner.sock|/tmp/idfon-owner.log|/tmp/idfon-state.backup.json) continue ;;
    esac
    rm -rf "$f"
done

echo "e2e-teardown: done (test edge + app edge config intentionally kept)"
