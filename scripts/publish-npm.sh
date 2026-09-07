#!/bin/sh
# Publish the idfon npm packages (main + 4 platform binaries) with an OTP pin.
#
# Usage:
#   scripts/publish-npm.sh <otp-pin> [run-id]
#
# Platform tarballs come from the given (or latest successful) npm CI run;
# the main idfon package is packed fresh from ./npm/idfon. Platform packages
# publish first so idfon's optionalDependencies resolve immediately.
# Requires an authenticated npm login (npm login); the OTP pin is from your
# authenticator — one pin covers the whole batch.
#
# DRY_RUN=1 scripts/publish-npm.sh <otp> [run-id]  — download + pack only.
set -eu
otp=${1:?usage: scripts/publish-npm.sh <otp-pin> [run-id]}
[ $# -gt 1 ] && run=$2 || run=""

repo=donpark/idfon
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(node -p "require('$root/npm/idfon/package.json').version")

npm whoami >/dev/null 2>&1 || { echo "publish-npm.sh: not logged in — run 'npm login' first" >&2; exit 1; }

if [ -z "$run" ]; then
  run=$(gh run list --repo "$repo" --workflow npm.yml --status success -L 1 --json databaseId --jq '.[0].databaseId')
  [ -n "$run" ] || { echo "publish-npm.sh: no successful npm.yml run to publish from" >&2; exit 1; }
fi
echo "publish-npm.sh: publishing $version from CI run $run"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh run download "$run" --repo "$repo" --dir "$work"
# Artifacts download into per-artifact subdirs; flatten.
find "$work" -name '*.tgz' -exec mv {} "$work/" \;

publish() {
  if [ -n "${DRY_RUN:-}" ]; then echo "DRY: npm publish $*"; else npm publish "$@"; fi
}

for pkg in idfon-darwin-arm64 idfon-darwin-x64 idfon-linux-arm64 idfon-linux-x64; do
  if npm view "$pkg@$version" version >/dev/null 2>&1; then
    echo "publish-npm.sh: $pkg@$version already published, skipping"
    continue
  fi
  publish "$work/$pkg-$version.tgz" --access public --otp="$otp"
done

npm pack "$root/npm/idfon" --pack-destination "$work"
if npm view "idfon@$version" version >/dev/null 2>&1; then
  echo "publish-npm.sh: idfon@$version already published, nothing to do"
  exit 0
fi
publish "$work/idfon-$version.tgz" --access public --otp="$otp"
echo "publish-npm.sh: published idfon@$version + 4 platform packages"
