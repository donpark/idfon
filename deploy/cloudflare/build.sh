#!/bin/sh
# Builds the Worker wasm bundle into ./build.
#
# Two environment quirks this handles:
#   * macOS BSD `ar` produces an empty archive for wasm objects, so `ring`'s C
#     objects never link and the build fails with undefined `ring_core_*`
#     symbols. Use LLVM `ar`.
#   * `ring` cross-compiles C with the host clang; it must emit wasm objects.
set -eu

if [ "$(uname)" = "Darwin" ]; then
  export CC_wasm32_unknown_unknown="${CC_wasm32_unknown_unknown:-$(xcrun --find clang 2>/dev/null || echo clang)}"
  if [ -z "${AR_wasm32_unknown_unknown:-}" ]; then
    for candidate in llvm-ar /opt/homebrew/opt/llvm/bin/llvm-ar /opt/homebrew/opt/llvm@22/bin/llvm-ar /usr/local/opt/llvm/bin/llvm-ar; do
      if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
        AR_wasm32_unknown_unknown="$candidate"
        break
      fi
    done
  fi
  if [ -z "${AR_wasm32_unknown_unknown:-}" ]; then
    echo "error: llvm-ar not found (brew install llvm)" >&2
    exit 1
  fi
  export AR_wasm32_unknown_unknown
fi

exec worker-build --release "$@"
