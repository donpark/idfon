#!/usr/bin/env bash
# Serve a built speech-model pack (see `scripts/build-speech-pack.sh`) over
# plain HTTP on the LAN, for device provisioning.
#
# Usage: scripts/serve-speech-pack.sh [pack-root] [port]
#        (defaults: dist/speech-packs, 8788)
#
# Prints the base URL to pass to the app:
#   xcrun devicectl device process launch --console --device <UDID> \
#     --terminate-existing app.idfon -- -speechpackurl <base>/kokoro-ane/
set -euo pipefail

dir="${1:-dist/speech-packs}"
port="${2:-8788}"
if [ ! -d "$dir" ]; then
    echo "error: $dir not found; run scripts/build-speech-pack.sh first" >&2
    exit 1
fi

ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)
echo "serving $dir on port $port"
echo "  base URL: http://$ip:$port/kokoro-ane/"
exec python3 -m http.server "$port" --directory "$dir"
