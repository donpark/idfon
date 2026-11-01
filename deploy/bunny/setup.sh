#!/usr/bin/env bash
# Provision the bunny.net pull zone in front of the edge's durable files
# (docs/durable-files.md). Idempotent; safe to re-run.
#
#   BUNNYNET_API_KEY=... deploy/bunny/setup.sh            # create/converge
#   BUNNYNET_API_KEY=... deploy/bunny/setup.sh --check    # read-only report
#
# Env:
#   BUNNYNET_API_KEY      required; bunny.net dashboard -> Account -> API Key
#   DIGITALOCEAN_API_KEY  optional; when set (and doctl is installed) the
#                         files.<domain> CNAME is created/updated too
#   IDFON_BUNNY_ZONE      pull zone name (default idfon-files)
#   IDFON_EDGE_ORIGIN     origin URL (default https://idfon.net)
#   IDFON_FILES_HOST      custom hostname (default files.idfon.net)
#   IDFON_DOMAIN          apex for the CNAME record (default idfon.net)
set -euo pipefail

# One gitignored file for both deploy scripts. Explicit env still wins for the
# two keys, so a one-off BUNNYNET_API_KEY=... invocation is not overridden.
DEPLOY_ENV="$(cd "$(dirname "$0")/../digitalocean" && pwd)/.env"
if [ -f "$DEPLOY_ENV" ]; then
    _explicit_bunny="${BUNNYNET_API_KEY:-}"
    _explicit_do="${DIGITALOCEAN_API_KEY:-}"
    set -a
    # shellcheck disable=SC1090
    . "$DEPLOY_ENV"
    set +a
    [ -n "$_explicit_bunny" ] && BUNNYNET_API_KEY="$_explicit_bunny"
    [ -n "$_explicit_do" ] && DIGITALOCEAN_API_KEY="$_explicit_do"
    unset _explicit_bunny _explicit_do
fi
API="${IDFON_BUNNY_API:-https://api.bunny.net}"
KEY="${BUNNYNET_API_KEY:-}"
ZONE="${IDFON_BUNNY_ZONE:-idfon-files}"
ORIGIN="${IDFON_EDGE_ORIGIN:-https://idfon.net}"
HOST="${IDFON_FILES_HOST:-files.idfon.net}"
DOMAIN="${IDFON_DOMAIN:-idfon.net}"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }

[ -n "$KEY" ] || die "set BUNNYNET_API_KEY (bunny.net dashboard -> Account -> API Key)"
command -v curl >/dev/null || die "curl not found"
command -v python3 >/dev/null || die "python3 not found"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# api METHOD PATH [JSON] -> response body, fails on HTTP >= 400
api() {
    local method=$1 path=$2 data=${3:-} code
    if [ -n "$data" ]; then
        code=$(curl -sS -o "$TMP/body" -w '%{http_code}' -X "$method" "$API$path" \
            -H "AccessKey: $KEY" -H "Content-Type: application/json" --data "$data")
    else
        code=$(curl -sS -o "$TMP/body" -w '%{http_code}' -X "$method" "$API$path" \
            -H "AccessKey: $KEY")
    fi
    if [ "$code" -ge 400 ]; then
        printf 'bunny: %s %s -> %s: %s\n' "$method" "$path" "$code" "$(cat "$TMP/body")" >&2
        return 1
    fi
    cat "$TMP/body"
}

# jget EXPR reads JSON on stdin and evaluates EXPR where `z` is the object.
jget() { python3 -c "import json,sys; z=json.load(sys.stdin); print($1)" 2>/dev/null || true; }

# The writeable settings this pull zone converges to. Smart Cache stays OFF:
# it restricts caching to known extensions, and content URLs are extensionless
# hex paths. Cache overrides stay -1 (bunny's "no override") so the origin's
# Cache-Control is authoritative — that is where the rental TTL and the
# no-store for mutable names live. 0 would mean "cache for 0 seconds".
SETTINGS=$(python3 - "$ORIGIN" <<'PY'
import json, sys
print(json.dumps({
    "OriginType": 0,
    "OriginUrl": sys.argv[1],
    "OriginHostHeader": "",
    "AddHostHeader": False,
    "VerifyOriginSSL": True,
    "FollowRedirects": False,
    "EnableSmartCache": False,
    "CacheControlMaxAgeOverride": -1,
    "CacheControlPublicMaxAgeOverride": -1,
    "CacheControlBrowserMaxAgeOverride": -1,
    "IgnoreQueryStrings": False,
    "EnableRequestCoalescing": True,
    "EnableOriginShield": False,
    "EnableCacheSlice": False,
    "EnableTLS1": False,
    "EnableTLS1_1": False,
    "EnableLogging": False,
}, separators=(",", ":")))
PY
)

say "pull zone $ZONE (origin $ORIGIN)"
ZONES=$(api GET "/pullzone?search=$ZONE")
ID=$(printf '%s' "$ZONES" | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
zones = data.get("Items", []) if isinstance(data, dict) else data
print(next((str(z["Id"]) for z in zones if z.get("Name") == name), ""))
' "$ZONE")

if [ -z "$ID" ]; then
    if [ "$CHECK" = 1 ]; then
        die "pull zone $ZONE does not exist (run without --check to create it)"
    fi
    BODY=$(python3 - "$ZONE" "$SETTINGS" <<'PY'
import json, sys
body = json.loads(sys.argv[2])
body["Name"] = sys.argv[1]
print(json.dumps(body, separators=(",", ":")))
PY
)
    CREATED=$(api POST "/pullzone" "$BODY")
    ID=$(printf '%s' "$CREATED" | jget 'z["Id"]')
    [ -n "$ID" ] || die "bunny did not return a pull zone id"
    info "created id $ID"
else
    info "id $ID"
    if [ "$CHECK" = 0 ]; then
        MERGED=$(python3 - "$ID" "$ZONE" "$SETTINGS" <<'PY'
import json, sys
body = json.loads(sys.argv[3])
body["Id"] = int(sys.argv[1])
body["Name"] = sys.argv[2]
print(json.dumps(body, separators=(",", ":")))
PY
)
        api POST "/pullzone/$ID" "$MERGED" >/dev/null || die "updating the pull zone failed"
        info "settings converged"
    fi
fi

ZONE_JSON=$(api GET "/pullzone/$ID")
# CnameDomain is just the base (b-cdn.net); the target is the system hostname.
CNAME=$(printf '%s' "$ZONE_JSON" | jget 'next((h["Value"] for h in z.get("Hostnames") or [] if h.get("IsSystemHostname")), "")')
[ -n "$CNAME" ] || CNAME="$ZONE.b-cdn.net"
origin_now=$(printf '%s' "$ZONE_JSON" | jget 'z.get("OriginUrl") or ""')
smart_now=$(printf '%s' "$ZONE_JSON" | jget 'z.get("EnableSmartCache")')
cache_now=$(printf '%s' "$ZONE_JSON" | jget 'z.get("CacheControlMaxAgeOverride")')
info "origin   $origin_now"
info "smart cache $smart_now, cache override ${cache_now}s (-1 = origin)"
[ -n "$CNAME" ] || die "bunny returned no CnameDomain"

say "custom hostname $HOST"
HOST_JSON=$(printf '%s' "$ZONE_JSON" | python3 -c '
import json, sys
host = sys.argv[1]
zone = json.load(sys.stdin)
print(json.dumps(next((h for h in zone.get("Hostnames") or [] if h.get("Value") == host), {})))
' "$HOST")
if [ "$HOST_JSON" = "{}" ]; then
    if [ "$CHECK" = 1 ]; then
        info "not added yet"
    else
        api POST "/pullzone/$ID/addHostname" "{\"Hostname\":\"$HOST\"}" >/dev/null
        info "added"
        ZONE_JSON=$(api GET "/pullzone/$ID")
        HOST_JSON=$(printf '%s' "$ZONE_JSON" | python3 -c '
import json, sys
host = sys.argv[1]
zone = json.load(sys.stdin)
print(json.dumps(next((h for h in zone.get("Hostnames") or [] if h.get("Value") == host), {})))
' "$HOST")
    fi
fi
has_cert=$(printf '%s' "$HOST_JSON" | jget 'z.get("HasCertificate")')
force_ssl=$(printf '%s' "$HOST_JSON" | jget 'z.get("ForceSSL")')
info "certificate $has_cert, force SSL $force_ssl"

say "DNS: $HOST CNAME $CNAME"
case "$HOST" in
    *."$DOMAIN") DNAME=${HOST%.$DOMAIN} ;;
    *) die "$HOST is not under $DOMAIN (set IDFON_DOMAIN)" ;;
esac
if command -v doctl >/dev/null && [ -n "${DIGITALOCEAN_API_KEY:-}" ]; then
    export DIGITALOCEAN_ACCESS_TOKEN="$DIGITALOCEAN_API_KEY"
    if [ "$CHECK" = 1 ]; then
        doctl compute domain records list "$DOMAIN" --format Type,Name,Data --no-header \
            | awk -v n="$DNAME" '$1 == "CNAME" && $2 == n { print "   record: " $0 }'
    else
        current=$(doctl compute domain records list "$DOMAIN" --format ID,Type,Name,Data --no-header \
            | awk -v n="$DNAME" '$2 == "CNAME" && $3 == n')
        if [ -n "$current" ]; then
            printf '%s\n' "$current" | while read -r rid rtype rname rdata; do
                if [ "${rdata%.}" != "$CNAME" ]; then
                    doctl compute domain records delete "$DOMAIN" "$rid" --force >/dev/null
                    info "replaced stale $rname -> $rdata"
                fi
            done
        fi
        if ! doctl compute domain records list "$DOMAIN" --format Type,Name,Data --no-header \
            | awk -v n="$DNAME" -v c="$CNAME" '
                { data = $3; sub(/\.$/, "", data) }
                $1 == "CNAME" && $2 == n && data == c { found = 1 }
                END { exit !found }'; then
            doctl compute domain records create "$DOMAIN" --record-type CNAME \
                --record-name "$DNAME" --record-data "$CNAME." --record-ttl 300 >/dev/null
            info "created CNAME"
        fi
    fi
else
    info "add at DigitalOcean (or any DNS host): CNAME $DNAME -> $CNAME  (TTL 300)"
fi

# The free certificate only issues once the CNAME resolves to bunny.net.
if [ "$has_cert" != "True" ]; then
    if [ "$CHECK" = 1 ]; then
        info "certificate not issued yet; re-run without --check once DNS resolves"
    else
        api GET "/pullzone/loadFreeCertificate?hostname=$HOST" >/dev/null \
            || die "loadFreeCertificate failed (DNS not propagated? re-run in a few minutes)"
        sleep 3
        ZONE_JSON=$(api GET "/pullzone/$ID")
        has_cert=$(printf '%s' "$ZONE_JSON" | python3 -c '
import json, sys
host = sys.argv[1]
zone = json.load(sys.stdin)
print(next((h.get("HasCertificate") for h in zone.get("Hostnames") or [] if h.get("Value") == host), False))
' "$HOST")
        info "certificate $has_cert"
        [ "$has_cert" = "True" ] || die "certificate not issued yet; re-run in a few minutes"
    fi
fi

if [ "$has_cert" = "True" ] && [ "$force_ssl" != "True" ] && [ "$CHECK" = 0 ]; then
    api POST "/pullzone/$ID/setForceSSL" "{\"Hostname\":\"$HOST\",\"ForceSSL\":true}" >/dev/null
    info "force SSL enabled"
fi

say "done"
info "content:  https://$HOST/sha256/<hash>"
info "names:    https://$HOST/<name>  (also /models/<name>)"
info "origin stays the droplet; keep IDFON_EDGE_URL there for idfon publish"
