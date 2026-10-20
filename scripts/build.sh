#!/usr/bin/env bash
# Build everything the daemons and agents need, in dependency order — or
# clean it. Extra args (e.g. `pnpm build all`) are accepted and ignored.
#
#   pnpm build   # voice stack -> daemon/CLI -> Eve bundles
#   pnpm clean   # every package's clean + agent build outputs
#
# Run this before `pnpm agent restart all`: the serve scripts rebuild on any
# source newer than the binaries, so a fresh tree restarts in seconds instead
# of minutes with no agent answering.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
mode=build
[ "${1:-}" = clean ] && mode=clean

if [ "$mode" = clean ]; then
  pnpm cli clean
  pnpm mac clean
  pnpm ios clean
  pnpm native clean
  pnpm eve clean
  bash scripts/voice.sh clean
  exit 0
fi

# 1. Voice stack first: the iroh C FFI dylib every binary links against, the
#    eve-idfon-voice holder, both signed.
bash scripts/voice.sh build

# 2. Daemon + CLI.
cargo build --release -p idfond -p idfon-cli
codesign --force -s - target/release/idfond

# 3. Eve agent bundles (extension first, then agents/*).
bash scripts/eve.sh build
