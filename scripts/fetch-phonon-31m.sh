#!/usr/bin/env bash
# Provision the Phonon 31m Core ML model bundle (gradium's phonon-31m-en
# export) where the apps' PhononTtsEngine expects it:
#   mac:  ~/.idfon/models/phonon   (ModelStore.root/phonon)
#   ios:  side-load the same layout into the app's Documents/phonon, or serve
#         DEST and set IDFON_PHONON_PACK_URL to it (bundle.json layout).
#
#   scripts/fetch-phonon-31m.sh [DEST] [ZIP]
#
# DEST: default $IDFON_HOME/models/phonon.
# ZIP:  a local phonon-31m-en-coreml.zip (default: download the pinned v0.4.0
#       release and verify its sha256).
#
# Custom voices are 256KB .safetensors embeddings dropped in DEST/voices/
# (picked with IDFON_TTS_VOICE=NAME). voices/ is preserved across re-fetches.
# shortcut: the bundle replaces wholesale on upgrade (PhononModels contract),
# so voices/ is the only kept state — revisit if per-voice metadata appears.
set -euo pipefail

DEST="${1:-}"
[ -n "$DEST" ] || DEST="${IDFON_HOME:-$HOME/.idfon}/models/phonon"
ZIP="${2:-}"
URL="https://github.com/gradium-ai/xn-ptts/releases/download/v0.4.0/phonon-31m-en-coreml.zip"
SHA256="10f3a99fd39256db44f826267ef21d78cca959b16c0554926344c09fde27b436"

work=$(mktemp -d /tmp/phonon-31m.XXXXXX)
trap 'rm -rf "$work"' EXIT

if [ -z "$ZIP" ]; then
  ZIP="$work/phonon-31m-en-coreml.zip"
  echo "downloading $URL"
  curl -fL -o "$ZIP" "$URL"
fi
echo "$SHA256  $ZIP" | shasum -a 256 -c - >/dev/null \
  || { echo "FAIL: sha256 mismatch for $ZIP" >&2; exit 2; }

unzip -q "$ZIP" -d "$work/unzip"
src="$work/unzip/phonon-31m-en-coreml"
[ -f "$src/bundle.json" ] || { echo "FAIL: no bundle.json in $src" >&2; exit 2; }

mkdir -p "$DEST"
# voices/ lives inside the bundle dir; keep user voices across re-fetches.
if [ -d "$DEST/voices" ]; then mv "$DEST/voices" "$work/voices-keep"; fi
rm -rf "$DEST.tmp"
mv "$src" "$DEST.tmp"
rm -rf "$DEST"
mv "$DEST.tmp" "$DEST"
if [ -d "$work/voices-keep" ]; then mv "$work/voices-keep" "$DEST/voices"; fi

echo "phonon models ready: $DEST ($(du -sh "$DEST" | cut -f1))"
