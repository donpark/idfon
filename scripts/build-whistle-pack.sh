#!/usr/bin/env bash
# Build the Whistle speech-model pack for direct-download provisioning.
#
# Whistle is a single 16.9 MB `.cact` file (Cactus Compute, Apache-2.0). Serve
# the output with `scripts/serve-speech-pack.sh`; the app pulls it when
# `IDFON_WHISTLE_PACK_URL` (or `-whistlepackurl`) points at
# `<base>/whistle/`.
#
# Usage: scripts/build-whistle-pack.sh [out-dir]   (default: dist/speech-packs)
set -euo pipefail

out="${1:-dist/speech-packs}"
pack="$out/whistle"
url="https://huggingface.co/Cactus-Compute/whistle/resolve/main/whistle.cact"

mkdir -p "$pack"
if [ ! -f "$pack/whistle.cact" ]; then
    echo "downloading whistle.cact …"
    curl -fsSL --retry 3 -o "$pack/whistle.cact" "$url"
fi

python3 - "$pack" <<'PY'
import hashlib, json, os, sys
pack = sys.argv[1]
files = []
for name in sorted(os.listdir(pack)):
    if name == "manifest.json":
        continue
    full = os.path.join(pack, name)
    digest = hashlib.sha256(open(full, "rb").read()).hexdigest()
    files.append({"path": name, "bytes": os.path.getsize(full), "sha256": digest})
manifest = {"id": "whistle", "version": 1, "files": files}
with open(os.path.join(pack, "manifest.json"), "w") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
print(f"  {len(files)} files, {sum(f['bytes'] for f in files)/1e6:.1f} MB")
PY

echo "done -> $pack"
echo "serve:  scripts/serve-speech-pack.sh $out"
