#!/bin/sh
# Room fan-out acceptance (docs/chatrooms.md, milestone R0).
#
# One `room.send` from A must reach two members with the *same* `conversation`,
# riding the ordinary `message.send` path — no protocol change, no new
# transport, no room-specific authorization. The only room state is A's local
# member list.
#
#   scripts/room-e2e.sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

pnpm cli build

work=$(mktemp -d /tmp/idfon-room.XXXXXX)
pids=""
cleanup() {
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  [ -n "$pids" ] && wait $pids 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

NUF="$root/target/release/idfon"
ROOM="r_$(printf '%032d' 7)"

for who in a b c; do
  mkdir -p "$work/$who"
  target/release/idfond --socket "$work/$who/idfond.sock" --data-dir "$work/$who" \
    >"$work/$who.log" 2>&1 &
  pids="$pids $!"
done

sock() { printf '%s' "$work/$1/idfond.sock"; }

for who in a b c; do
  for _ in $(seq 1 150); do
    if "$NUF" --socket "$(sock "$who")" status --json >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
done

identity_field() {
  "$NUF" --socket "$(sock "$1")" status --json | jq -r ".result.identity.$2"
}

A_PID=$(identity_field a public_key); A_EID=$(identity_field a endpoint_id); A_ADDR=$($NUF --socket "$(sock a)" status --json | jq -r '.result.ticket | implode')
B_PID=$(identity_field b public_key); B_EID=$(identity_field b endpoint_id); B_ADDR=$($NUF --socket "$(sock b)" status --json | jq -r '.result.ticket | implode')
C_PID=$(identity_field c public_key); C_EID=$(identity_field c endpoint_id); C_ADDR=$($NUF --socket "$(sock c)" status --json | jq -r '.result.ticket | implode')

# Add the other two peers on every daemon and grant both directions. This is the
# ordinary peer path — nothing here is room-specific.
for entry in "a $B_PID $B_EID $B_ADDR" "a $C_PID $C_EID $C_ADDR" \
             "b $A_PID $A_EID $A_ADDR" "b $C_PID $C_EID $C_ADDR" \
             "c $A_PID $A_EID $A_ADDR" "c $B_PID $B_EID $B_ADDR"; do
  # shellcheck disable=SC2086
  set -- $entry
  self=$1; peer=$2; endpoint=$3; address=$4
  "$NUF" --socket "$(sock "$self")" peer add "$peer" --name "$peer" \
    --endpoint-id "$endpoint" --endpoint-addr "$address" --json >/dev/null
  for capability in message.send message.receive; do
    "$NUF" --socket "$(sock "$self")" access allow --subject "$peer" \
      --capability "$capability" --json >/dev/null
  done
done

# Follow the members before sending so nothing is missed.
"$NUF" --socket "$(sock b)" events --follow --type message.received >"$work/b.events" 2>&1 &
pids="$pids $!"
"$NUF" --socket "$(sock c)" events --follow --type message.received >"$work/c.events" 2>&1 &
pids="$pids $!"
sleep 0.5

"$NUF" --socket "$(sock a)" room create --id "$ROOM" --name design \
  --member "$B_PID" --member "$C_PID" --json >"$work/room.json"
"$NUF" --socket "$(sock a)" room send "$ROOM" --text "hello room" \
  --idempotency-key room-e2e-1 --json >"$work/send.json"

for _ in $(seq 1 200); do
  if grep -q "hello room" "$work/b.events" 2>/dev/null \
     && grep -q "hello room" "$work/c.events" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

status=0
for who in b c; do
  if ! grep -q "hello room" "$work/$who.events" 2>/dev/null; then
    echo "FAIL: $who did not receive the room message" >&2
    status=1
    continue
  fi
  got=$(grep "hello room" "$work/$who.events" | head -n 1 | jq -r '.data.conversation')
  if [ "$got" != "$ROOM" ]; then
    echo "FAIL: $who saw conversation '$got', expected '$ROOM'" >&2
    status=1
  else
    echo "ok: $who received room $ROOM"
  fi
done

if [ "$status" = 0 ]; then
  echo "PASS: room fan-out delivered to both members under one conversation"
else
  exit 1
fi
