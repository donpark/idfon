#!/usr/bin/env bash
# Build the Kokoro-ANE speech-model pack for direct-download provisioning.
#
# Fetches only what FluidAudio's `KokoroAneManager` needs — the 7-stage CoreML
# chain, `vocab.json`, and the default voice (`af_heart.bin`) — lays them out
# the way the engine caches them (`<root>/kokoro-82m-coreml/ANE/…`), and writes
# `manifest.json` next to them. Serve the output with
# `scripts/serve-speech-pack.sh`; the app pulls it when `IDFON_KOKORO_PACK_URL`
# (or `-speechpackurl`) points at `<base>/kokoro-ane/`.
#
# Usage: scripts/build-speech-pack.sh [out-dir]   (default: dist/speech-packs)
set -euo pipefail

repo="FluidInference/kokoro-82m-coreml"
subdir="ANE"
out="${1:-dist/speech-packs}"
pack="$out/kokoro-ane"
# The engine appends this to the directory it is given (Repo.kokoroAne.folderName).
layout="kokoro-82m-coreml/$subdir"
root="$pack/$layout"
api="https://huggingface.co/api/models/$repo/tree/main/$subdir?recursive=true"
dl="https://huggingface.co/$repo/resolve/main"

want=$(cat <<'EOF'
KokoroAlbert.mlmodelc
KokoroPostAlbert.mlmodelc
KokoroAlignment.mlmodelc
KokoroProsody_v2.mlmodelc
KokoroNoise_v2.mlmodelc
KokoroVocoder.mlmodelc
KokoroTail_v2.mlmodelc
EOF
)

mkdir -p "$root"
listing=$(mktemp)
trap 'rm -f "$listing"' EXIT
echo "listing $repo/$subdir …"
curl -fsSL "$api" -o "$listing"

echo "resolving required files …"
paths=()
while IFS= read -r line; do
    paths+=("$line")
done < <(python3 - "$listing" "$want" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
want = set(sys.argv[2].split())
for entry in data:
    if entry.get("type") != "file":
        continue
    path = entry["path"]
    if (any(f"/{w}/" in path or path.endswith(f"/{w}") for w in want)
            or path in (f"ANE/vocab.json", f"ANE/af_heart.bin")):
        print(path)
PY
)
if [ "${#paths[@]}" -eq 0 ]; then
    echo "error: HuggingFace returned no matching files" >&2
    exit 1
fi

echo "downloading ${#paths[@]} files (${subdir}/) …"
for path in ${paths[@]+"${paths[@]}"}; do
    rel="${path#"$subdir"/}"
    dest="$root/$rel"
    if [ -f "$dest" ]; then
        continue
    fi
    mkdir -p "$(dirname "$dest")"
    curl -fsSL --retry 3 -o "$dest" "$dl/$path"
    printf '  %s\n' "$rel"
done

echo "writing manifest.json …"
python3 - "$pack" "$layout" <<'PY'
import hashlib, json, os, sys
pack, layout = sys.argv[1], sys.argv[2]
files = []
for base, _dirs, names in os.walk(pack):
    for name in names:
        if name == "manifest.json":
            continue
        full = os.path.join(base, name)
        rel = os.path.relpath(full, pack)
        digest = hashlib.sha256(open(full, "rb").read()).hexdigest()
        files.append({"path": rel, "bytes": os.path.getsize(full), "sha256": digest})
files.sort(key=lambda f: f["path"])
manifest = {"id": "kokoro-ane", "version": 1, "layout": layout, "files": files}
with open(os.path.join(pack, "manifest.json"), "w") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
print(f"  {len(files)} files, {sum(f['bytes'] for f in files)/1e6:.1f} MB")
PY

echo "done -> $pack"
echo "serve:  scripts/serve-speech-pack.sh $out"
