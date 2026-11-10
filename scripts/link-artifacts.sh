#!/usr/bin/env bash
# Link the shared generated-artifact store (~/.idfon/{bench-results,dist}) into
# this checkout. These hold multi-GB model-testing/training outputs; the store
# is shared across worktrees so each instance does not grow its own copy.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for d in bench-results dist; do
  if [ -e "$root/$d" ] || [ -L "$root/$d" ]; then continue; fi
  mkdir -p "$HOME/.idfon/$d"
  ln -s "$HOME/.idfon/$d" "$root/$d"
  echo "linked $d -> $HOME/.idfon/$d"
done