#!/bin/bash
# Serve a voice agent that WRAPS the Agency.
#
# The caller talks to this voice agent (a live server-cascade call, or a voice
# memo); it turns speech into text and relays that text to the Agency, then
# speaks the Agency's reply. The Agency itself is unchanged and text-only.
#
# Prereqs:
#   - the Agency is running (`scripts/agency-serve.sh`) so `~/.idfon/agency`
#     has its holder key + ticket;
#   - AI_GATEWAY_API_KEY is set (default engine + the cascade holder).
#
#   scripts/agency-voice-serve.sh
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
agency_home="${AGENCY_HOME:-$HOME/.idfon/agency}"
agency_addr_file="$agency_home/holder.ticket"
[ -s "$agency_addr_file" ] || {
  echo "Agency not found at $agency_addr_file — start it with scripts/agency-serve.sh first" >&2
  exit 1
}
agency_peer=$(head -1 "$agency_addr_file" | jq -r .id)
[ -n "$agency_peer" ] && [ "$agency_peer" != null ] || {
  echo "cannot read the Agency endpoint id from $agency_addr_file" >&2
  exit 1
}

export EVE_AGENT="${EVE_AGENT:-voice-agent}"
export EVE_IDFON_PKG="${EVE_IDFON_PKG:-idfon-voice-agent}"
export EVE_IDFON_BIN="${EVE_IDFON_BIN:-eve-idfon-voice}"

instance="${EVE_INSTANCE:-$EVE_AGENT}"
home="${EVE_VOICE_HOME:-$HOME/.idfon/$instance}"
key="$home/holder.key"
mkdir -p "$home"
if [ ! -s "$key" ]; then printf '%064d' "$((RANDOM * RANDOM))" > "$key"; fi

# This voice agent's own endpoint id (derived from its key, before the holder
# starts) so we can mint the Agency-issued ticket and admit both directions.
self_id="$("$root/target/release/$EVE_IDFON_BIN" --key-file "$key" ticket --subject self 2>/dev/null | jq -r .issuer)"
[ -n "$self_id" ] && [ "$self_id" != null ] || {
  echo "cannot derive the voice-agent endpoint id" >&2
  exit 1
}

# Agency-issued ticket authorizing this voice agent to message the Agency, and
# admission on the Agency's allow-list (its holder reloads the file live).
agency_ticket="$("$root/target/release/$EVE_IDFON_BIN" --key-file "$agency_home/holder.key" ticket --subject "$self_id" 2>/dev/null)"
[ -n "$agency_ticket" ] || { echo "cannot mint an Agency ticket for $self_id" >&2; exit 1; }
grep -qxF "$self_id" "$agency_home/allowed-peers" 2>/dev/null || printf '%s\n' "$self_id" >> "$agency_home/allowed-peers"
# Admit the Agency as a sender on this voice agent's holder so its replies land.
grep -qxF "$agency_peer" "$home/allowed-peers" 2>/dev/null || printf '%s\n' "$agency_peer" >> "$home/allowed-peers"

# Agent-side config: providers (default AI Gateway) + the wrapped target.
base="${IDFON_VOICE_ENGINE:-{\"stt\":{\"provider\":\"openai-compatible\"},\"tts\":{\"provider\":\"openai-compatible\"}}}"
export IDFON_VOICE_ENGINE="$(jq -nc \
  --argjson base "$base" \
  --argjson ticket "$agency_ticket" \
  --arg peer "$agency_peer" \
  '$base + { wrap: { peer_id: $peer, endpoint_id: $peer, ticket: $ticket } }')"

. "$root/scripts/live-voice-serve.sh" "$@"
