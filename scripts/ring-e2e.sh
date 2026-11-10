#!/bin/bash
# Wake-chain regression — the 2026-11-10 test-rig session, scripted.
#
# Asserts the machine-checkable links of the lock-screen ring chain:
#   1. the phone's PushKit token registers at the edge (push-state),
#   2. the caller's ring POST reaches the edge and fans out (rung >= 1),
#   3. the push wakes the phone app and the delegate runs
#      (`idfon push: incoming` in the phone's per-run log).
# The human verifies the system ring UI itself (and can answer/hang up when
# run with --keep).
#
# Usage: scripts/ring-e2e.sh --device UDID [--peer iphone] [--no-build] [--keep]
#   --keep   leave edge + apps running for manual follow-up (answer legs, C20)
# Env: APNS_KEY (default ~/.idfon/edge.apns.p8), APNS_KEY_ID (A9R2SP5259 —
#   verify with scripts/apns-key-probe.mjs), APNS_TEAM (RV27HPQNMF),
#   EDGE_PORT (8090). The phone must be UNLOCKED for pairing/install steps;
#   the script prompts when it must be LOCKED.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
device="${IPHONE_UDID:-${IPHONE_NAME:-}}"
peer="iphone" build=1 keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --device) device="$2"; shift 2;;
    --peer) peer="$2"; shift 2;;
    --no-build) build=0; shift;;
    --keep) keep=1; shift;;
    *) echo "usage: $0 --device UDID [--peer REF] [--no-build] [--keep]" >&2; exit 2;;
  esac
done
[ -n "$device" ] || { echo "FAIL: no device (set IPHONE_UDID or --device)"; exit 2; }
key="${APNS_KEY:-$HOME/.idfon/edge.apns.p8}"
keyid="${APNS_KEY_ID:-A9R2SP5259}"
team="${APNS_TEAM:-RV27HPQNMF}"
port="${EDGE_PORT:-8090}"
lan=$(ipconfig getifaddr en1 2>/dev/null || ipconfig getifaddr en0)
edge_log=/tmp/ring-e2e-edge.log
mac_log=/tmp/ring-e2e-mac.log
state=/tmp/ring-e2e-push.json
fail() { echo "FAIL: $1"; [ -f "$edge_log" ] && tail -5 "$edge_log"; exit 1; }

if [ "$build" = 1 ]; then
  echo "== build (edge + mac app)"
  (cd "$root" && cargo build -p idfon-edge) || fail "edge build"
  (cd "$root/mac" && bash build.sh >/dev/null) || fail "mac app build"
fi

echo "== start test edge on :$port"
pkill -f "idfon-edge --bind 0.0.0.0:$port" 2>/dev/null || true
rm -f "$state" /tmp/ring-e2e-edge.key
(cd "$root" && RUST_LOG=idfon_edge=info,idfon.edge.access=info,idfon.edge.push=warn \
  nohup ./target/debug/idfon-edge --bind "0.0.0.0:$port" --token e2etoken \
    --push-apns-key "$key" --push-apns-key-id "$keyid" --push-apns-team "$team" \
    --push-apns-url https://api.sandbox.push.apple.com \
    --push-state "$state" --key-file /tmp/ring-e2e-edge.key \
    > "$edge_log" 2>&1 &)
sleep 2

echo "== start mac app + pair"
pkill -f "Idfon.app/Contents/MacOS/Idfon" 2>/dev/null || true
sleep 1
nohup "$root/mac/build/Idfon.app/Contents/MacOS/Idfon" \
  -edgeurl "http://127.0.0.1:$port" -edgeticket e2e > "$mac_log" 2>&1 &
for _ in $(seq 1 30); do [ -S /tmp/idfon/idfond.sock ] && break; sleep 1; done
[ -S /tmp/idfon/idfond.sock ] || fail "mac daemon socket never appeared"
"$root/scripts/pair-apple-channels.sh" --device "$device" >/dev/null || fail "pairing"
cli="$root/target/release/idfon"
"$cli" --socket /tmp/idfon/idfond.sock peer update "$peer" --call-mode call_kit >/dev/null \
  || fail "peer update --call-mode call_kit"

echo "== phone: register push token"
"$root/scripts/device-lock.sh" xcrun devicectl device process launch --device "$device" \
  --terminate-existing --console com.idfon.ios -- \
  -edgeurl "http://$lan:$port" -edgeticket e2e > /tmp/ring-e2e-phone.log 2>&1 &
for _ in $(seq 1 30); do
  [ -s "$state" ] && grep -q voip "$state" 2>/dev/null && break
  sleep 1
done
grep -q voip "$state" 2>/dev/null || fail "push token never registered (see /tmp/ring-e2e-phone.log)"
echo "ok: token registered"

echo "== kill phone app, then LOCK the phone and press Enter"
"$root/scripts/device-lock.sh" xcrun devicectl device process terminate --device "$device" \
  --pid "$("$root/scripts/device-lock.sh" xcrun devicectl device info processes --device "$device" 2>/dev/null | grep -i idfon | grep -oE '^[[:space:]]*[0-9]+' | head -1 | tr -d ' ')" >/dev/null 2>&1 || true
read -r

echo "== dial from mac"
pkill -f "Idfon.app/Contents/MacOS/Idfon" 2>/dev/null || true
sleep 1
nohup "$root/mac/build/Idfon.app/Contents/MacOS/Idfon" \
  -edgeurl "http://127.0.0.1:$port" -edgeticket e2e -dial "$peer" > "$mac_log" 2>&1 &
for _ in $(seq 1 30); do
  grep -q "_push/ring.*status=200" <(sed 's/\x1b\[[0-9;]*m//g' "$edge_log") 2>/dev/null && break
  sleep 1
done
sed 's/\x1b\[[0-9;]*m//g' "$edge_log" | grep -q "_push/ring.*status=200" || fail "ring POST never reached the edge"
grep -q "rung=1\|rung=[2-9]" "$mac_log" || fail "edge fanned out to zero devices (rung=0)"
echo "ok: ring reached the edge and fanned out"

echo "== phone delegate marker (give the push a few seconds)"
sleep 6
phone_pid=$("$root/scripts/device-lock.sh" xcrun devicectl device info files --device "$device" \
  --domain-type appDataContainer --domain-identifier com.idfon.ios --subdirectory tmp 2>/dev/null \
  | grep -oE 'idfon-app-[0-9]+\.log' | tail -1 || true)
[ -n "$phone_pid" ] || fail "phone app log not found (was the push delivered?)"
"$root/scripts/device-lock.sh" xcrun devicectl device copy from --device "$device" \
  --domain-type appDataContainer --domain-identifier com.idfon.ios \
  --source "tmp/$phone_pid" --destination /tmp/ring-e2e-phone-run.log >/dev/null 2>&1 \
  || fail "could not pull the phone app log (unlock the phone?)"
grep -q "idfon push: incoming" /tmp/ring-e2e-phone-run.log \
  || fail "push never reached the phone delegate (delivery suppressed or APNs env wrong)"
echo "ok: push woke the phone and the delegate ran"

echo "PASS: wake chain (registration -> ring fan-out -> delegate)"
echo "manual legs remain: system ring visible, answer -> two-way audio (C20), hangup"
if [ "$keep" = 0 ]; then
  echo "(teardown: pkill -f idfon-edge; pkill -f 'Idfon.app/Contents/MacOS/Idfon'; rm -f /tmp/ring-e2e-*)"
fi
