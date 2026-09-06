#!/bin/sh
set -eu

# End-to-end data transfer between two endpoints over the real daemon
# protocol, driven through the idfon CLI with bash-pipe semantics:
#
#   idfond (endpoint A) <- stdin/file -- idfon put  --> BlobTicket
#   idfond (endpoint B) -- idfon get TICKET --> stdout/file
#
# Cases: one-chunk binary, multi-chunk binary (exercises the chunked
# put/sliced-fetch path), and a WAV audio file. PASS requires every received
# file to be byte-identical to its original.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# Build the vendored dylib first (the thin idfond links it); flags must match
# native/build.zig so the dylib's install name stays @executable_path-relative.
RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
  cargo build --release --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
cargo build --release -p idfond -p idfon-cli

# A relink can leave an ad-hoc signature that no longer matches the pages;
# the kernel then SIGKILLs the process at exec ("Code Signature Invalid").
codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond

work=$(mktemp -d /tmp/idfon-e2e.XXXXXX)
pids=""
cleanup() {
  if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

NUF="$root/target/release/idfon"
A="$work/sender/idfond.sock"
B="$work/receiver/idfond.sock"

# Test data: 64KB random (one chunk), 1.25MB random (7 chunks), 1s sine WAV.
head -c 65536 /dev/urandom > "$work/small.bin"
head -c 1250000 /dev/urandom > "$work/big.bin"
python3 - "$work/audio.wav" <<'EOF'
import math, struct, sys, wave
with wave.open(sys.argv[1], "w") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(8000)
    w.writeframes(b"".join(
        struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / 8000)))
        for i in range(8000)))
EOF

mkdir -p "$work/sender" "$work/receiver"
"$root/target/release/idfond" --socket "$A" --data-dir "$work/sender" &
pids="$pids $!"
"$root/target/release/idfond" --socket "$B" --data-dir "$work/receiver" &
pids="$pids $!"

wait_ready() { # socket label
  for _ in $(seq 1 100); do
    if "$NUF" --socket "$1" status --json >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "FAIL: daemon $2 not ready" >&2
  exit 1
}
wait_ready "$A" sender
wait_ready "$B" receiver

check() { # label original received
  if cmp -s "$2" "$3"; then
    echo "PASS: $1 ($(wc -c < "$3") bytes identical)"
  else
    echo "FAIL: $1 differs from original" >&2
    exit 1
  fi
}

# 1. Small file, --file source, --out sink.
ticket=$("$NUF" --socket "$A" put --file "$work/small.bin")
"$NUF" --socket "$B" get "$ticket" --out "$work/small.received"
check "one-chunk file" "$work/small.bin" "$work/small.received"

# 2. Multi-chunk through bash pipes on both ends.
ticket=$("$NUF" --socket "$A" put < "$work/big.bin")
"$NUF" --socket "$B" get "$ticket" > "$work/big.received"
check "chunked 1.25MB pipe" "$work/big.bin" "$work/big.received"

# 3. Audio file round trip.
ticket=$("$NUF" --socket "$A" put < "$work/audio.wav")
"$NUF" --socket "$B" get "$ticket" > "$work/audio.received"
check "audio wav" "$work/audio.wav" "$work/audio.received"

# 4. Signaled transfer through the message path: pair the daemons (cross
# peer.add with endpoint info + grants), then send-data/recv.
ctx() { "$NUF" --socket "$1" context --json; }
A_EP=$(ctx "$A" | jq -r .result.identity.endpoint_id)
A_PID=$(ctx "$A" | jq -r .result.identity.public_key)
A_ADDR=$(ctx "$A" | jq -r '.result.ticket | implode')
B_EP=$(ctx "$B" | jq -r .result.identity.endpoint_id)
B_PID=$(ctx "$B" | jq -r .result.identity.public_key)
B_ADDR=$(ctx "$B" | jq -r '.result.ticket | implode')
"$NUF" --socket "$A" peer add "$B_PID" --name bob --endpoint-id "$B_EP" --endpoint-addr "$B_ADDR"
"$NUF" --socket "$B" peer add "$A_PID" --name alice --endpoint-id "$A_EP" --endpoint-addr "$A_ADDR"
"$NUF" --socket "$A" access grant --subject "$B_PID" --capability message.send
"$NUF" --socket "$B" access grant --subject "$A_PID" --capability message.receive
head -c 300000 /dev/urandom > "$work/signaled.bin"
"$NUF" --socket "$B" recv > "$work/signaled.received" &
recv_pid=$!
"$NUF" --socket "$A" send bob --file --retries 2 < "$work/signaled.bin" > "$work/signaled.ticket"
wait "$recv_pid"
check "signaled send-data/recv" "$work/signaled.bin" "$work/signaled.received"

echo "PASS: idfon put/get end-to-end over two daemon endpoints"
