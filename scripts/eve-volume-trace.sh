#!/usr/bin/env bash
# One-command capture for the ai-voice-chat live-call volume reset.
#
# Tails the holder log, launches the iOS app with --console, and saves both
# streams to a timestamped directory. Make one call with two GPT-Live turns,
# then Ctrl-C here; the script prints the lines that matter.
#
#   scripts/eve-volume-trace.sh [app arguments...]
#
# App arguments go to `devicectl ... app.idfon -- <args>` (e.g. pairing args).
# Run the ai-voice-chat holder first (scripts/ai-voice-chat-serve.sh).
set -euo pipefail

home=${EVE_VOICE_HOME:-"$HOME/.idfon/ai-voice-chat"}
out=/tmp/idfon-volume-trace-$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"

udid=${IPHONE_UDID:-${DEVICE:-}}
if [[ -z "$udid" ]]; then
  # Match the physical row (devicectl reports it as "available (paired)" or
  # "connected", with either a UUID or the ECID-style UDID before " (UDID)").
  udid=$(xcrun devicectl list devices 2>/dev/null \
    | grep -E 'physical' | grep -vE 'unavailable|shutdown' \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f-]+ \(UDID\)' \
    | head -1 | sed 's/ (UDID)//' || true)
fi
if [[ -z "$udid" ]]; then
  echo "no physical iOS device detected; set IPHONE_UDID or DEVICE. Devices:" >&2
  xcrun devicectl list devices >&2 2>&1 || true
  exit 1
fi

holder_logs=()
if [[ -f "$home/holder.log" ]]; then holder_logs+=("$home/holder.log"); fi
for log in /tmp/idfon-holder-*.log; do
  if [[ -f "$log" ]]; then holder_logs+=("$log"); fi
done
if [[ ${#holder_logs[@]} -eq 0 ]]; then
  echo "warning: no holder log under $home or /tmp — is the holder running?" >&2
fi

tail_pid=
app_pid=
stream_pid=
cleanup() {
  local pid
  for pid in "$tail_pid" "$stream_pid" "$app_pid"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  tail_pid=; stream_pid=; app_pid=
}
trap cleanup EXIT INT TERM

if [[ ${#holder_logs[@]} -gt 0 ]]; then
  tail -n +1 -F "${holder_logs[@]}" >"$out/holder.log" 2>&1 &
  tail_pid=$!
fi

echo "capture dir: $out"
echo "make one call with two GPT-Live turns; Ctrl-C here when done"

launch=(device process launch --device "$udid" --terminate-existing --console app.idfon)
if [[ $# -gt 0 ]]; then launch+=(-- "$@"); fi
# devicectl ignores SIGINT, so run it as a child and kill it ourselves on
# Ctrl-C; piping it in the foreground only kills `tee` and the attach lingers.
xcrun devicectl "${launch[@]}" >"$out/ios-console.log" 2>&1 &
app_pid=$!
tail -n +1 -f "$out/ios-console.log" &
stream_pid=$!
wait "$app_pid" 2>/dev/null || true
app_pid=

cleanup
echo
echo "== iOS: idfon live call: / idfon volume / [media] =="
grep -nE 'idfon live call:|idfon volume|\[media\]' "$out/ios-console.log" || true
echo
echo "== holder (last 80 lines) =="
[[ -f "$out/holder.log" ]] && tail -n 80 "$out/holder.log" || true
echo
echo "saved: $out/ios-console.log  $out/holder.log"
