#!/usr/bin/env bash
# Provision a Pocket TTS v4 pack (Kyutai's 2026-10 small models, incl. the
# reward fine-tuned `_refl` twins) into the cache path FluidAudio's
# PocketTtsModelStore expects, so the `pocket` TTS backend loads it instead of
# downloading the ~767 MB v2.1 pack.
#
#   scripts/fetch-pocket-v4.sh [PACK] [DEST]
#
# PACK: v4/<pack> under FluidInference/pocket-tts-coreml
#       (default: english_18m_refl_2026-10 — the reward fine tuned 18M).
#       Others: english_18m_2026-10, english_7m_2026-10, english_7m_refl_2026-10,
#       english_2m_2026-10, english_2m_refl_2026-10.
# DEST: the PocketTtsManager `directory:` root
#       (default: ~/.idfon/models/pocket — matches PocketTtsEngine).
#
# Layout: DEST/Models/pocket-tts-coreml/v2.1/english/ holds the pack's files —
# the v2.1 language-root path is where the store looks for .english, and the
# v4 pack satisfies the .aneState required set (pocket_state.mlmodelc,
# mimi_decoder.mlmodelc, constants_bin/). The duplicate .mlpackage copies are
# skipped (the .mlmodelc set loads as-is). Voice cloning's shared root Mimi
# encoder is NOT fetched: without it cloning falls back to the approximate
# legacy reprojection path (see FluidAudio #793).
set -euo pipefail
PACK="${1:-english_18m_refl_2026-10}"
DEST="${2:-$HOME/.idfon/models/pocket}"
REPO="FluidInference/pocket-tts-coreml"
ROOT="$DEST/Models/pocket-tts-coreml/v2.1/english"
mkdir -p "$ROOT"
python3 - "$REPO" "$PACK" "$ROOT" <<'PY'
import json, os, sys, urllib.request
repo, pack, root = sys.argv[1], sys.argv[2], sys.argv[3]
api = f"https://huggingface.co/api/models/{repo}?blobs=true"
files = json.load(urllib.request.urlopen(api))["siblings"]
prefix = f"v4/{pack}/"
picked = [f for f in files
          if f["rfilename"].startswith(prefix)
          and ".mlpackage" not in f["rfilename"]
          and not f["rfilename"].endswith(".DS_Store")]
total = sum(f.get("size") or 0 for f in picked)
print(f"{len(picked)} files, {total / 1e6:.0f} MB -> {root}")
from concurrent.futures import ThreadPoolExecutor

def fetch(f):
    rel = f["rfilename"][len(prefix):]
    dest = os.path.join(root, rel)
    size = f.get("size") or 0
    if os.path.exists(dest) and os.path.getsize(dest) == size:
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    url = f"https://huggingface.co/{repo}/resolve/main/{f['rfilename']}"
    urllib.request.urlretrieve(url, dest)
    print("  got", rel, f"{size / 1e6:.1f} MB")

# Parallel pulls: the host is a CDN and the files are large — 8-wide.
with ThreadPoolExecutor(max_workers=8) as pool:
    list(pool.map(fetch, picked))
print("done — restart the app with IDFON_TTS=pocket")
PY
