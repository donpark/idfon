#!/bin/sh
set -eu

# Live video streaming between two iroh-live endpoints over the real daemon
# protocol, driven through the idfon CLI (no capture device, no GUI):
#
#   idfond (endpoint A) -- idfon send --stream --video --file vid.mp4 --> ticket
#   idfond (endpoint B) -- idfon get TICKET --video --out rec.h264
#
# The source is an ffmpeg test pattern fragmented to CMAF. The publisher
# decodes it and simulcasts it as an H.264 rendition ladder; the subscriber
# records the highest rendition as Annex B H.264, playable with ffplay/mpv.
# The recorded stream is validated with ffprobe (decodable frame count).
#
# Requires: ffmpeg on PATH (source generation + validation only).

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# Build the vendored dylib first (the thin idfond links it); flags must match
# native/build.zig so the dylib's install name stays @executable_path-relative.
RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p idfond -p idfon-cli
# A relink can leave an ad-hoc signature that no longer matches the pages;
# the kernel then SIGKILLs the process at exec ("Code Signature Invalid").
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond target/release/idfon

work=$(mktemp -d /tmp/idfon-video-e2e.XXXXXX)
pids=""
cleanup() {
  if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

NUF="$root/target/release/idfon"
A="$work/publisher/idfond.sock"
B="$work/listener/idfond.sock"

# Test source: 320x240 test pattern, 4s, H.264 baseline (openh264-compatible:
# no B-frames), one fragment per keyframe (~0.5s GOPs). openh264, which
# decodes the stream on the publish side, only supports baseline profile.
ffmpeg -v error -y -f lavfi -i testsrc=duration=4:size=320x240:rate=15 \
  -pix_fmt yuv420p -c:v libx264 -profile:v baseline -level 3.0 -bf 0 \
  -g 15 -force_key_frames "expr:gte(t,n_forced*0.5)" \
  -movflags +frag_keyframe+empty_moov+default_base_moof \
  "$work/vid.mp4"

mkdir -p "$work/publisher" "$work/listener"
"$root/target/release/idfond" --socket "$A" --data-dir "$work/publisher" &
pids="$pids $!"
"$root/target/release/idfond" --socket "$B" --data-dir "$work/listener" &
pids="$pids $!"

wait_ready() { # socket label
  for _ in $(seq 1 100); do
    if "$NUF" --socket "$1" status >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "$2: daemon did not become ready" >&2
  exit 1
}
wait_ready "$A" publisher
wait_ready "$B" listener

# Publish the video file as a live broadcast; the ticket is the capability.
ticket=$("$NUF" --socket "$A" send --stream --video --file "$work/vid.mp4" --name vidtest)
case "$ticket" in
  iroh-live:*) echo "publish: ticket ok" ;;
  *) echo "publish: unexpected ticket: $ticket" >&2; exit 1 ;;
esac

# Subscribe from the second endpoint: record the highest rendition.
"$NUF" --socket "$B" get "$ticket" --video --seconds 6 --out "$work/rec.h264" --json \
  > "$work/subscribe.json"
frames=$(python3 -c "import json;print(json.load(open('$work/subscribe.json'))['result']['frames'])")
bytes=$(python3 -c "import json;print(json.load(open('$work/subscribe.json'))['result']['bytes'])")
echo "subscribe: frames=$frames bytes=$bytes"
[ "$frames" -ge 30 ] || { echo "expected >=30 frames, got $frames" >&2; exit 1; }
[ "$bytes" -ge 10000 ] || { echo "expected >=10000 bytes, got $bytes" >&2; exit 1; }

# The recording must be a decodable Annex B H.264 elementary stream.
count=$(ffprobe -v error -count_frames -select_streams v -show_entries \
  stream=nb_read_frames -of default=nw=1:nk=1 -f h264 "$work/rec.h264")
echo "ffprobe: decoded $count frames"
[ "$count" -ge 30 ] || { echo "ffprobe decoded only $count frames" >&2; exit 1; }

echo "video e2e: OK"
