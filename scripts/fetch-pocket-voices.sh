#!/usr/bin/env bash
# Fetch the replicated Kokoro voices for Pocket TTS (cloned voices, 512KB
# each) from the donpark/pocket-kokoro-voices HF repo into the app's pocket
# voices directory, where PocketTtsEngine resolves them by name
# (IDFON_TTS_VOICE=af_heart etc.).
#
#   scripts/fetch-pocket-voices.sh [DEST]
#
# DEST: voices directory (default: ~/.idfon/models/pocket/voices — matches
# PocketTtsEngine on mac; iOS side-loads into Documents/pocket-voices/).
# Only *_audio_prompt.bin files are fetched (the *_probe.wav samples stay on
# the repo page).
set -euo pipefail
DEST="${1:-$HOME/.idfon/models/pocket/voices}"
REPO="donpark/pocket-kokoro-voices"
mkdir -p "$DEST"
python3 - "$REPO" "$DEST" <<'PY'
import json, os, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor
repo, dest = sys.argv[1], sys.argv[2]
files = json.load(urllib.request.urlopen(
    f"https://huggingface.co/api/models/{repo}"))["siblings"]
picked = [f for f in files if f["rfilename"].endswith("_audio_prompt.bin")]

def fetch(f):
    out = os.path.join(dest, os.path.basename(f["rfilename"]))
    if os.path.exists(out):
        return
    urllib.request.urlretrieve(
        f"https://huggingface.co/{repo}/resolve/main/{f['rfilename']}", out)
    print("  got", os.path.basename(out))

print(f"{len(picked)} voices -> {dest}")
with ThreadPoolExecutor(max_workers=8) as pool:
    list(pool.map(fetch, picked))
print("done")
PY
