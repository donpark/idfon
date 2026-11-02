#!/bin/bash
# Admit one app (an iPhone) to a running talk-radio station, without restarting
# it, and print the single launch that adds the contact and installs the ticket
# it must present.
#
#   scripts/radio-admit.sh "tech talk" <ios-peer-id>
#
# Why two credentials: a contact (peer.add) says *who* to talk to; the holder
# gates every message on a capability ticket issued by itself, bound to the
# sender (`ticket.subject == sender.peer_id`), and the app has no in-app paste
# for one — only `-pair-ticket` at launch. This script mints that ticket and
# appends the sender to the holder's allow file, which the holder reloads every
# 500 ms, so the station does not need a restart.
#
# Find the peer id by adding the contact once (`devicectl ... -- -pair '<contact>'
# '<name>' -pair-exit`); the app logs `idfon self ticket: {… "endpoint_id" …}`.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
station="${1:-}"
peer="${2:-}"
if [ -z "$station" ] || [ -z "$peer" ]; then
  echo "usage: radio-admit.sh <roster topic|instance|name> <ios-peer-id>" >&2
  exit 1
fi

# Resolve the station and make sure its state exists; prints instance, name,
# live config path.
info=$(node "$root/scripts/radio-program.mjs" config "$station" 2>/dev/null)
instance=$(printf '%s\n' "$info" | sed -n 1p)
name=$(printf '%s\n' "$info" | sed -n 2p)
live_config=$(printf '%s\n' "$info" | sed -n 3p)
if [ -z "$instance" ] || [ -z "$live_config" ]; then
  echo "radio-admit: could not resolve station '$station'" >&2
  exit 1
fi

home="${EVE_VOICE_HOME:-$HOME/.idfon/$instance}"
key="$home/holder.key"
contact_file="$home/holder.ticket"
holder_bin="$root/target/release/eve-idfon-voice"
if [ ! -s "$key" ] || [ ! -s "$contact_file" ]; then
  echo "radio-admit: $instance has no identity yet — run it once first:" >&2
  echo "  scripts/radio-serve.sh '$station'" >&2
  exit 1
fi
if [ ! -x "$holder_bin" ]; then
  echo "radio-admit: $holder_bin is missing — run scripts/radio-serve.sh once" >&2
  exit 1
fi

# A subagent appends here too (docs/live-radio.md); the holder reloads it while
# running, so admitting a phone never requires a restart.
touch "$home/allowed-peers"
if ! grep -qxF "$peer" "$home/allowed-peers" 2>/dev/null; then
  printf '%s\n' "$peer" >> "$home/allowed-peers"
fi

ticket_file="$home/capability-ticket-$peer.json"
"$holder_bin" --key-file "$key" --live-config "$live_config" ticket --subject "$peer" > "$ticket_file"
ticket=$(cat "$ticket_file")
holder=$(jq -r .id "$contact_file")
contact=$(head -n 1 "$contact_file")
if [ -z "$holder" ] || [ "$holder" = null ]; then
  echo "radio-admit: could not read the holder id from $contact_file" >&2
  exit 1
fi

echo "admitted $peer to $name ($instance); ticket -> $ticket_file" >&2
echo "the holder picks the allow entry up within a second; no restart needed." >&2
echo >&2
echo "Run this once, then open the app and call the contact:" >&2
cat <<EOF
xcrun devicectl device process launch --console <udid> com.idfon.ios -- \\
  -pair '$contact' '$name' -pair-ticket '$holder' '$ticket' -pair-exit
EOF
