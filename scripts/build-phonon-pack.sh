#!/usr/bin/env bash
# Build the Phonon 31m model pack for direct-download provisioning — the
# gradium Core ML export plus the idfon voice set, served whole as a
# PhononModels bundle (bundle.json + every file it lists).
#
# Usage: scripts/build-phonon-pack.sh [out-root] [voices-dir]
#        (defaults: dist/speech-packs, docs/voice-compare-audio/voices)
#
# Output: <out-root>/phonon-31m/ — serve it with
#   scripts/serve-speech-pack.sh <out-root>
# and point the app at <base>/phonon-31m/ (IDFON_PHONON_PACK_URL /
# -phononpack / the engine's defaultPackURL constant).
#
# The bundle.json `built` stamp is derived from the file set, so adding or
# changing voices makes installed packs re-download (PhononModels replaces the
# whole directory and only files listed in bundle.json survive an upgrade —
# which is why the voices must be listed).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/dist/speech-packs}"
voices="${2:-$root/docs/voice-compare-audio/voices}"
pack="$out/phonon-31m"

if [ ! -d "$voices" ] || ! ls "$voices"/*.safetensors >/dev/null 2>&1; then
    echo "error: no *.safetensors voices in $voices (run scripts/phonon-voice-compare.py)" >&2
    exit 1
fi

echo "provisioning the pinned phonon-31m export …"
rm -rf "$pack/voices"   # clean voice slate: the export ships 38 stock voices
"$root/scripts/fetch-phonon-31m.sh" "$pack"

# The 18 blend parents + stock Miles stay out of shipped packs (2026-10-31
# curation): they are confusable with the idfon blends above. Kept stock rides
# along from the export; the blends add on top.
echo "pruning the confusable stock voices …"
for n in Maeve Harper Everly Imogen Hadley Delia Zoey Freya Elodie-Rose Juniper \
         Edwin Preston Easton Alfie Trevor Micah Hugh Spencer Miles; do
    rm -f "$pack/voices/$n.safetensors"
done

echo "adding $(ls "$voices"/*.safetensors | wc -l | tr -d ' ') voices …"
mkdir -p "$pack/voices"
cp "$voices"/*.safetensors "$pack/voices/"

rm -rf "$pack/sha256"   # stale content-addressed links
echo "writing bundle.json …"
python3 - "$pack" <<'PY'
import hashlib, json, os, sys
pack = sys.argv[1]

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

files = []
for base, _dirs, names in os.walk(pack):
    for name in names:
        if name == "bundle.json":
            continue
        full = os.path.join(base, name)
        files.append({
            "path": os.path.relpath(full, pack),
            "size": os.path.getsize(full),
            "sha256": sha256(full),
        })
files.sort(key=lambda f: f["path"])
# Content-derived stamp: a changed voice set must read as a new export, or
# PhononModels.download skips it (it compares `built` against what is installed).
stamp = hashlib.sha256(
    "".join(f"{f['path']}:{f['sha256']}\n" for f in files).encode()
).digest()
built = int.from_bytes(stamp[:8], "big") >> 1  # positive Int64 for Swift's decoder
manifest = {"built": built, "files": files}
with open(os.path.join(pack, "bundle.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
v = [f for f in files if f["path"].startswith("voices/")]
print(f"  {len(files)} files ({sum(f['size'] for f in files)/1e6:.1f} MB), {len(v)} voices, built={built}")
PY

# Content-addressed copies for the app downloader and the CDN (hardlinks).
python3 "$root/scripts/link-phonon-sha256.py" "$pack"

echo "done -> $pack"
echo "serve:  scripts/serve-speech-pack.sh $out   (pack URL: <base>/phonon-31m/)"
echo "publish:"
echo "  rsync -a --chmod=D755,F644 '$pack/sha256/' <droplet>:/srv/idfon-edge/files/sha256/"
echo "  rsync -a --chmod=D755,F644 '$pack/bundle.json' <droplet>:/srv/idfon-edge/files/$(basename "$pack")/bundle.json"
