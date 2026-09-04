#!/bin/sh
set -eu

profile=${1:?usage: $0 PROFILE}
case "$profile" in
  *[!A-Za-z0-9_-]*|'')
    echo "profile must contain only letters, numbers, '-' or '_'" >&2
    exit 2
    ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec env IDFON_PROFILE="$profile" "$root/Idfon.app/Contents/MacOS/Idfon"
