#!/bin/sh
set -eu

# Relay A/B matrix over the real daemon stack (docs/benchmarks.md).
# Thin wrapper over the pure-TS bench vertical (agents/bench/lib/) — the same
# code the bench Eve agent's tools run. No Rust is compiled here for third
# parties: it uses the `idfon`/`idfond` binaries (npm `idfon` platform packages
# ship prebuilt ones; a repo checkout builds them on demand).
#
#   scripts/relay-bench.sh [matrix] [--quick] [--count N] [--blob-bytes N]
#                              [--relay URL] [--out FILE]
#   scripts/relay-bench.sh rtt --to PEER [--socket S] [--count N]
#
# matrix runs one fresh daemon pair per relay config (n0, n0-relay-only,
# idfon, idfon-relay-only) and appends JSONL rows to bench-results/. The
# *-relay-only rows force the relay path, so the relay comparison is honest
# even on one host; other rows take whatever path iroh picks. rtt measures a
# peer through an already-running daemon (its relay config applies).
#
# Binaries: env IDFON_CLI / IDFOND_BIN, else target/release/, else PATH.

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# Enterprise relay token (shared_token mode, docs/benchmarks.md): env wins,
# else the local secret file the deploy prints for ~/.idfon/relay-token.
if [ -z "${IDFON_RELAY_TOKEN:-}" ] && [ -f "$HOME/.idfon/relay-token" ]; then
  IDFON_RELAY_TOKEN=$(cat "$HOME/.idfon/relay-token")
  export IDFON_RELAY_TOKEN
fi

# `idfond` is a launcher: the daemon lives in libiroh_c_ffi.dylib, built
# separately (docs/build.md). Build the whole chain every run (fresh builds
# are near-instant) or a crates/ change is silently not what gets measured.
# Ad-hoc sign after relink — a stale signature gets SIGKILLed at exec.
if [ -z "${IDFON_CLI:-}" ]; then
  if [ "$(uname)" = Darwin ]; then
    RUSTFLAGS="-C link-arg=-Wl,-install_name,@executable_path/libiroh_c_ffi.dylib" \
      cargo build --release --quiet --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
    cargo build --release --quiet -p idfon-cli -p idfond
    codesign --force -s - target/release/libiroh_c_ffi.dylib target/release/idfond
  else
    cargo build --release --quiet --manifest-path native/vendor/iroh-c-ffi/Cargo.toml
    cargo build --release --quiet -p idfon-cli -p idfond
  fi
fi

case "${1:-}" in
  rtt) shift; exec node "$root/agents/bench/lib/bench.ts" rtt "$@" ;;
  matrix) shift ;;
  -h|--help|help) sed -n '2,18p' "$0"; exit 0 ;;
esac
exec node "$root/agents/bench/lib/bench.ts" matrix "$@"
