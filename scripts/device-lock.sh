#!/bin/bash
# Serialize access to the one shared iPhone.
#
# An agent thread that installs or launches on the phone while another thread
# is doing the same gets SBMainWorkspace denials, and worse, the *other*
# thread's build can end up being the one under test. This wraps a command in
# an exclusive fcntl lock on a machine-wide file, so the second caller waits
# instead of racing.
#
#   scripts/device-lock.sh xcrun devicectl device install app --device <udid> App.app
#
# Every device-touching command should go through this (or through
# `ios/device.sh`, which uses it). `lockf -t` is BSD base, no extra deps.
#
#   IDFON_DEVICE_LOCK        lock file   (default /tmp/idfon-iphone.lock)
#   IDFON_DEVICE_LOCK_WAIT   seconds     (default 1800: a full build+install)
set -euo pipefail
lock="${IDFON_DEVICE_LOCK:-/tmp/idfon-iphone.lock}"
wait="${IDFON_DEVICE_LOCK_WAIT:-1800}"
exec /usr/bin/lockf -t "$wait" "$lock" "$@"
