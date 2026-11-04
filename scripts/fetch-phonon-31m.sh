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

# The export writes the flow LM's weights into both flow-c414-t1 and
# flow-c414-t48 (same bytes, same sha256 in bundle.json): 55 MB of the 170 MB
# bundle for one 240 KB graph difference. Hardlink them so the pack, a served
# copy and the phone's installed copy hold one (the apps' PhononBundle does
# the same after a download).
python3 - "$DEST" <<'PY'
import json, os, sys
root = sys.argv[1]
by = {}
for f in json.load(open(os.path.join(root, "bundle.json")))["files"]:
    if f["size"] >= 1 << 20:
        by.setdefault(f["sha256"], []).append(os.path.join(root, f["path"]))
saved = 0
for paths in by.values():
    donor = paths[0]
    for path in paths[1:]:
        if not os.path.exists(path) or os.stat(path).st_ino == os.stat(donor).st_ino:
            continue
        staged = path + ".link"
        try:
            os.link(donor, staged)
            os.replace(staged, path)
            saved += os.stat(path).st_size
        except OSError:
            if os.path.exists(staged):
                os.remove(staged)
print(f"deduped: {saved / 1e6:.1f} MB shared")
PY

# A kept voices/ is user state (custom 256 KB embeddings) but bundle.json still
# lists the export's voices: a served DEST then fails every client install on a
# size/SHA-256 mismatch, which the app reports as a phonon failure and hides
# behind the Apple fallback. Make the manifest describe what is on disk.
python3 - "$DEST" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
path = os.path.join(root, "bundle.json")
manifest = json.load(open(path))
files, dropped, fixed = [], 0, 0
for f in manifest["files"]:
    if not f["path"].startswith("voices/"):
        files.append(f)
        continue
    target = os.path.join(root, f["path"])
    if not os.path.isfile(target):
        dropped += 1
        continue
    digest = hashlib.sha256(open(target, "rb").read()).hexdigest()
    size = os.path.getsize(target)
    if (size, digest) != (f["size"], f["sha256"]):
        fixed += 1
    files.append({"path": f["path"], "size": size, "sha256": digest})
manifest["files"] = files
json.dump(manifest, open(path, "w"), indent=1)
print(f"voices: {fixed} manifest entries updated, {dropped} dropped")
PY

echo "phonon models ready: $DEST ($(du -sh "$DEST" | cut -f1))"

# Serving DEST over HTTP still transfers both paths (the client asks for each
# file bundle.json lists); the saving there is the apps' PhononBundle, which
# downloads one copy per hash. A directory copy (side-load) keeps the link.
