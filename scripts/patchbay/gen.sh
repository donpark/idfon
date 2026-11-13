#!/bin/sh
# Patchbay NAT lab — see docs/relay-test-plan.md § "Network-path simulation".
#
# Writes the sim files for a cell into "$out" and prints the run command.
# Prerequisites (macOS): `container system start`, the patchbay CLI built for
# the guest arch (the release ships x86_64 only), an aarch64-musl patchbay
# runner, and musl builds of the tools each sim stages. The doc has the exact
# commands; this script only expands templates so the cells are reproducible.
#
#   scripts/patchbay/gen.sh punch        # UDP punch matrix (probe only)
#   scripts/patchbay/gen.sh iroh         # iroh-doctor + TLS/QAD relay
#   scripts/patchbay/gen.sh idfond       # two daemons + relay
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
kind=${1:?usage: gen.sh punch|iroh|idfond}
out=${2:-$root/out}
mkdir -p "$out"

case "$kind" in
  punch)
    for pair in open-open moderate-moderate moderate-strict strict-strict; do
      a=${pair%-*}; b=${pair#*-}
      sed -e "s/__PAIR__/$pair/g" -e "s/__A__/$a/g" -e "s/__B__/$b/g" \
        "$root/punch.toml" > "$out/punch-$pair.toml"
    done
    echo "probe: rustc --target aarch64-unknown-linux-musl \\"
    echo "  -C linker=aarch64-linux-musl-gcc -O -o $out/punch-aarch64 $root/punch.rs"
    ;;
  iroh|idfond)
    for cell in moderate strict; do
      sed -e "s/__CELL__/$cell/g" -e "s/__BOB_NAT__/$cell/g" \
        "$root/$kind.toml" > "$out/$kind-$cell.toml"
    done
    ;;
  *) echo "gen.sh: unknown cell: $kind" >&2; exit 2 ;;
esac

case "$kind" in
  punch) bins="--binary punch:path:$out/punch-aarch64" ;;
  iroh) bins="--binary doctor:path:<iroh-doctor> --binary relay:path:<iroh-relay>" ;;
  idfond) bins="--binary idfond:path:<idfond> --binary idfon:path:<idfon> --binary relay:path:<iroh-relay>" ;;
esac

cat <<EOF

run (from this directory):
  patchbay vm run $out --patchbay-version path:<runner> \\
    $bins
EOF
