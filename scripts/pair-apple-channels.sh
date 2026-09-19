#!/bin/bash
# Pair the active Mac and iOS identities with each other. An optional Eve
# ticket can also be injected when one is available.
#
#   pnpm pair
#   EVE_TICKET=... pnpm pair
#   pnpm pair --eve-ticket ticket.json
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cli="${IDFON_CLI:-$root/target/release/idfon}"
socket="${IDFON_SOCKET:-/tmp/idfon/idfond.sock}"
device="${IPHONE_UDID:-${IPHONE_NAME:-${DEVICE:-}}}"
eve_ticket="${EVE_TICKET:-}"

usage() {
  sed -n '2,9p' "$0"
  echo "  --eve-ticket JSON|FILE   Eve contact ticket (or EVE_TICKET)"
  echo "  --device ID_OR_NAME      iPhone (or IPHONE_UDID/IPHONE_NAME)"
  echo "  --socket PATH            Mac daemon socket (default /tmp/idfon/idfond.sock)"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --eve-ticket) eve_ticket="$2"; shift 2 ;;
    --device) device="$2"; shift 2 ;;
    --socket) socket="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [ -n "$eve_ticket" ]; then
  if [ -f "$eve_ticket" ]; then eve_ticket=$(<"$eve_ticket"); fi
  printf '%s' "$eve_ticket" | jq -e . >/dev/null || { echo "invalid Eve ticket JSON" >&2; exit 2; }
fi

if [ -z "$device" ]; then
  device=$(xcrun devicectl list devices 2>/dev/null \
    | grep -E "connected.*physical|physical.*connected" \
    | grep -m1 -oE '[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}' || true)
fi
[ -n "$device" ] || { echo "no connected iPhone; set IPHONE_UDID or IPHONE_NAME" >&2; exit 2; }

status=$($cli --socket "$socket" status --json)
mac_ticket=$(printf '%s' "$status" | jq -c '.result.contact_ticket')
mac_id=$(printf '%s' "$status" | jq -r '.result.identity.id')
[ "$mac_ticket" != null ] || { echo "Mac has no contact ticket" >&2; exit 1; }

add_mac() {
  local name=$1 ticket=$2
  local account endpoint addr
  account=$(printf '%s' "$ticket" | jq -r '.account_id // .endpoint_id // .id')
  endpoint=$(printf '%s' "$ticket" | jq -r '.endpoint_id // .id')
  # A contact ticket carries endpoint_addr as a serialized string; a raw
  # endpoint ticket is the address itself. The daemon dials the stored text
  # as EndpointAddr JSON, so it must not end up double-encoded.
  addr=$(printf '%s' "$ticket" | jq -r 'if (.endpoint_addr | type) == "string" then .endpoint_addr else (.endpoint_addr // .) | tojson end')
  $cli --socket "$socket" peer remove "$name" --identity "$mac_id" >/dev/null 2>&1 || true
  if ! $cli --socket "$socket" peer add "$account" --identity "$mac_id" --name "$name" \
    --endpoint-id "$endpoint" --endpoint-addr "$addr" >/dev/null 2>/tmp/idfon-pair-error; then
    if grep -q "peer name already exists" /tmp/idfon-pair-error; then
      $cli --socket "$socket" peer update "$account" --identity "$mac_id" \
        --name "$name" --endpoint-id "$endpoint" --endpoint-addr "$addr" >/dev/null
    else
      cat /tmp/idfon-pair-error >&2
      return 1
    fi
  fi
  for capability in message.send message.receive live.audio.subscribe; do
    $cli --socket "$socket" access allow --identity "$mac_id" \
      --subject "$account" --capability "$capability" >/dev/null
  done
}

# iOS receives current Mac and Eve tickets. Its launch console prints the
# current iOS ticket, which is then installed into the Mac daemon.
log=$(mktemp /tmp/idfon-pair-apple.XXXXXX)
cleanup() { rm -f "$log"; }
trap cleanup EXIT
# Unpair stale names in a separate launch: AppDelegate handles each request
# asynchronously, so mixing remove and add in one launch races them.
xcrun devicectl device process launch --device "$device" --terminate-existing --console \
  app.idfon -- -unpair mac -unpair mac-current >"$log" 2>&1 &
cleanup_launcher=$!
sleep 2
kill "$cleanup_launcher" 2>/dev/null || true
wait "$cleanup_launcher" 2>/dev/null || true
: >"$log"
# Add the current Mac and optional Eve tickets only after removals settle.
pair_args=(-pair "$mac_ticket" mac)
if [ -n "$eve_ticket" ]; then pair_args+=(-pair "$eve_ticket" eve); fi
xcrun devicectl device process launch --device "$device" --terminate-existing --console \
  app.idfon -- -pair-exit "${pair_args[@]}" >"$log" 2>&1 &
launcher=$!
for _ in $(seq 1 50); do
  if grep -q 'idfon paired:' "$log"; then break; fi
  kill -0 "$launcher" 2>/dev/null || break
  sleep 0.2
done
kill "$launcher" 2>/dev/null || true
wait "$launcher" 2>/dev/null || true
ios_ticket=$(grep 'idfon self ticket:' "$log" | sed 's/.*idfon self ticket: //' | tail -1)
[ -n "$ios_ticket" ] || { echo "iOS did not print its contact ticket" >&2; cat "$log" >&2; exit 1; }
printf '%s' "$ios_ticket" | jq -e . >/dev/null || { echo "invalid iOS ticket" >&2; exit 1; }

$cli --socket "$socket" peer remove iphone --identity "$mac_id" >/dev/null 2>&1 || true
$cli --socket "$socket" peer remove mac-current --identity "$mac_id" >/dev/null 2>&1 || true
add_mac iphone "$ios_ticket"
if [ -n "$eve_ticket" ]; then add_mac eve "$eve_ticket"; fi

echo "paired active identities: Mac <-> iPhone${eve_ticket:+ and Eve}"
echo "iOS device: $device"
echo "Mac peer list:"
$cli --socket "$socket" peer list --json | jq -r '.result.peers[] | "  \(.name): \(.id)"'
