#!/usr/bin/env python3
"""Build the content-addressed CDN tree for a built Phonon pack.

Reads <pack>/pack.json (the download index; `bundle.json` is the model
metadata and is one of the listed files), verifies each listed file's size and
SHA-256, and
places a hardlink at <pack>/sha256/<sha256> (copying if the filesystem refuses
the link). The app downloads `base/sha256/<sha256>` and installs at the
manifest `path`, so the Core ML layout and voice filenames are preserved while
the served bytes are content-addressed.

Usage: scripts/link-phonon-sha256.py <pack-dir>
"""
import hashlib
import json
import os
import shutil
import sys


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip())
    pack = sys.argv[1]
    with open(os.path.join(pack, "pack.json")) as f:
        manifest = json.load(f)
    out = os.path.join(pack, "sha256")
    os.makedirs(out, exist_ok=True)
    linked = existing = 0
    for entry in manifest["files"]:
        src = os.path.join(pack, entry["path"])
        if not os.path.isfile(src):
            sys.exit(f"missing {entry['path']}")
        if os.path.getsize(src) != entry["size"]:
            sys.exit(f"size mismatch: {entry['path']}")
        digest = sha256(src)
        if digest != entry["sha256"]:
            sys.exit(f"sha256 mismatch: {entry['path']}")
        dst = os.path.join(out, digest)
        if os.path.exists(dst):
            existing += 1
            continue
        try:
            os.link(src, dst)
            linked += 1
        except OSError:
            shutil.copy2(src, dst)
            linked += 1
    print(f"{out}: {linked} linked, {existing} already present")


if __name__ == "__main__":
    main()
