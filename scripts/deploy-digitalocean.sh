#!/usr/bin/env bash
# Deploy idfon-edge to a DigitalOcean droplet (idempotent; re-run to converge).
#
#   pnpm deploy:do
#
# Config comes from the environment or from deploy/digitalocean/.env (gitignored):
#   DIGITALOCEAN_API_KEY   required; DO token with read+write
#   IDFON_DOMAIN           default idfon.net
#   IDFON_EMAIL            default admin@<domain>
#   IDFON_DO_REGION        default nyc3
#   IDFON_DO_SIZE          default s-1vcpu-1gb-intel
#   IDFON_DO_IMAGE         default ubuntu-24-04-x64
#   IDFON_DO_NAME          default idfon-edge
#   IDFON_DO_SSH_KEY       private key path (default ~/.ssh/idfon_edge_ed25519,
#                          generated passphrase-free if missing)
#   IDFON_DO_RESERVED_IP   1 (default) create/assign a reserved IP, 0 = use ephemeral
#   IDFON_ADMIN_IP         /32 allowed to SSH (default: auto-detected)
#   IDFON_RELAY_URLS      set on the edge when the relay is deployed
#   IDFON_RELAY_TOKEN     shared-token relay access (falls back to the local
#                         secret file ~/.idfon/relay-token)
#   IDFON_RELAY_ALLOWLIST comma-separated endpoint ids the relay admits
#   IDFON_RELAY_AUTH_URL  relay HTTP-callout auth endpoint (optional)
#   IDFON_RELAY_AUTH_TOKEN bearer for the relay's callout (optional)
#   IDFON_RELAY_OPEN      1 = deliberately deploy an OPEN relay; without any
#                         auth config above the deploy refuses (fail-closed)
#   IDFON_EDGE_IMAGE       default ghcr.io/donpark/idfon-edge:latest
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEPLOY="$ROOT/deploy/digitalocean"

if [ -f "$DEPLOY/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$DEPLOY/.env"
  set +a
fi

TOKEN="${DIGITALOCEAN_API_KEY:-${DIGITALOCEAN_ACCESS_TOKEN:-}}"
DOMAIN="${IDFON_DOMAIN:-idfon.net}"
EMAIL="${IDFON_EMAIL:-admin@$DOMAIN}"
REGION="${IDFON_DO_REGION:-nyc3}"
SIZE="${IDFON_DO_SIZE:-s-1vcpu-1gb-intel}"
IMAGE="${IDFON_DO_IMAGE:-ubuntu-24-04-x64}"
NAME="${IDFON_DO_NAME:-idfon-edge}"
SSH_KEY="${IDFON_DO_SSH_KEY:-}"
USE_RESERVED_IP="${IDFON_DO_RESERVED_IP:-1}"
EDGE_IMAGE="${IDFON_EDGE_IMAGE:-ghcr.io/donpark/idfon-edge:latest}"
DEPLOY_RELAY="${IDFON_DEPLOY_RELAY:-0}"
# Relay access (shared_token mode): env wins, else the local secret file the
# deploy instructs you to keep at ~/.idfon/relay-token. Empty + no allowlist /
# auth URL = open relay — only deliberate, then.
RELAY_TOKEN="${IDFON_RELAY_TOKEN:-$(cat "$HOME/.idfon/relay-token" 2>/dev/null || true)}"
RELAY_ALLOWLIST="${IDFON_RELAY_ALLOWLIST:-}"
RELAY_AUTH_URL="${IDFON_RELAY_AUTH_URL:-}"
RELAY_AUTH_TOKEN="${IDFON_RELAY_AUTH_TOKEN:-}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

d() { doctl "$@"; }

command -v doctl >/dev/null || die "doctl not found (brew install doctl)"
command -v ssh >/dev/null || die "ssh not found"
command -v scp >/dev/null || die "scp not found"
[ -n "$TOKEN" ] || die "set DIGITALOCEAN_API_KEY (env or $DEPLOY/.env)"
export DIGITALOCEAN_ACCESS_TOKEN="$TOKEN"
d account get >/dev/null 2>&1 || die "DigitalOcean token rejected"

# --- SSH key: dedicated + passphrase-free, so ssh/scp work non-interactively --
say "SSH key"
KEY="${SSH_KEY:-$HOME/.ssh/idfon_edge_ed25519}"
case "$KEY" in *.pub) KEY="${KEY%.pub}" ;; esac
PUB="$KEY.pub"
if [ ! -f "$KEY" ]; then
  info "generating deploy key $KEY"
  mkdir -p "$(dirname "$KEY")"
  ssh-keygen -t ed25519 -N '' -f "$KEY" -C idfon-edge-deploy >/dev/null
fi
[ -f "$PUB" ] || die "ssh public key not found: $PUB"
FP_MD5="$(ssh-keygen -E md5 -lf "$PUB" | awk '{print $2}' | sed 's/^MD5://')"
SSH_KEY="$(d compute ssh-key list --format FingerPrint --no-header | awk -v fp="$FP_MD5" '$1==fp{print $1; exit}')"
if [ -z "$SSH_KEY" ]; then
  info "importing $PUB"
  SSH_KEY="$(d compute ssh-key import "$NAME" --public-key-file "$PUB" --format FingerPrint --no-header)"
fi
info "key $SSH_KEY ($PUB)"
SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

# --- droplet ---------------------------------------------------------------
say "droplet"
DROPLET_ID="$(d compute droplet list --format ID,Name --no-header | awk -v n="$NAME" '$2==n{print $1; exit}')"
if [ -z "$DROPLET_ID" ]; then
  info "creating $NAME ($SIZE, $REGION)"
  DROPLET_ID="$(d compute droplet create "$NAME" \
    --region "$REGION" --size "$SIZE" --image "$IMAGE" \
    --ssh-keys "$SSH_KEY" --user-data-file "$DEPLOY/cloud-init.yaml" \
    --enable-monitoring --wait --format ID --no-header)"
else
  # Reserved IPs are region-bound, so a region change is a recreate, not a
  # converge — refusing here beats silently keeping the old region.
  DROPLET_REGION="$(d compute droplet get "$DROPLET_ID" --format Region --no-header)"
  if [ "$DROPLET_REGION" != "$REGION" ]; then
    die "droplet $NAME exists in region $DROPLET_REGION but IDFON_DO_REGION=$REGION. Reserved IPs cannot move regions: snapshot if you care, delete the droplet (\`doctl compute droplet delete $NAME\`), then re-run to recreate in $REGION (DNS is re-pointed automatically)."
  fi
  info "reusing droplet $DROPLET_ID"
fi

# --- public IP -------------------------------------------------------------
say "public IP"
if [ "$USE_RESERVED_IP" = "1" ]; then
  PUBLIC_IP="$(d compute reserved-ip list --format IP,Region,DropletID --no-header | awk -v id="$DROPLET_ID" '$3==id{print $1; exit}')"
  if [ -z "$PUBLIC_IP" ]; then
    # Reuse an unassigned reserved IP in the region, else create one.
    PUBLIC_IP="$(d compute reserved-ip list --format IP,Region,DropletID --no-header \
      | awk -v r="$REGION" '$2==r && ($3=="" || $3=="0" || $3=="<nil>"){print $1; exit}')"
    [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(d compute reserved-ip create --region "$REGION" --format IP --no-header)"
    info "assigning reserved IP $PUBLIC_IP"
    d compute reserved-ip-action assign "$PUBLIC_IP" "$DROPLET_ID" >/dev/null
  fi
else
  PUBLIC_IP="$(d compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)"
fi
info "public IP: $PUBLIC_IP"

# --- firewall --------------------------------------------------------------
say "firewall"
ADMIN_IP="${IDFON_ADMIN_IP:-$(curl -fsS https://api.ipify.org || true)}"
[ -n "$ADMIN_IP" ] || die "could not detect your IP; set IDFON_ADMIN_IP"
FW_NAME="${NAME}-fw"
INBOUND="protocol:tcp,ports:22,address:${ADMIN_IP}/32 protocol:tcp,ports:80,address:0.0.0.0/0 protocol:tcp,ports:443,address:0.0.0.0/0 protocol:tcp,ports:8443,address:0.0.0.0/0 protocol:udp,ports:7842,address:0.0.0.0/0"
OUTBOUND="protocol:tcp,ports:all,address:0.0.0.0/0 protocol:udp,ports:all,address:0.0.0.0/0 protocol:icmp,address:0.0.0.0/0"
FW_ID="$(d compute firewall list --format ID,Name --no-header | awk -v n="$FW_NAME" '$2==n{print $1; exit}')"
if [ -z "$FW_ID" ]; then
  info "creating $FW_NAME (ssh from $ADMIN_IP; 80/443/8443 tcp + 7842 udp public)"
  d compute firewall create --name "$FW_NAME" \
    --inbound-rules "$INBOUND" --outbound-rules "$OUTBOUND" --droplet-ids "$DROPLET_ID" >/dev/null
else
  info "syncing rules + droplet on $FW_NAME"
  d compute firewall update "$FW_ID" --name "$FW_NAME" \
    --inbound-rules "$INBOUND" --outbound-rules "$OUTBOUND" --droplet-ids "$DROPLET_ID" >/dev/null
fi

# --- DNS zone + records ----------------------------------------------------
say "DNS zone + records"
d compute domain get "$DOMAIN" >/dev/null 2>&1 || d compute domain create "$DOMAIN" >/dev/null
add_a() { # name ip — upsert: stale A records for the name are replaced
  local found=0 id data
  while read -r id data; do
    if [ "$data" = "$2" ]; then
      found=1
    else
      d compute domain records delete "$DOMAIN" "$id" --force >/dev/null
      info "A $1 -> $data (removed stale)"
    fi
  done < <(d compute domain records list "$DOMAIN" --format ID,Type,Name,Data --no-header \
    | awk -v n="$1" '$2=="A" && $3==n {print $1, $4}')
  if [ "$found" = 1 ]; then
    info "A $1 -> $2 (exists)"
  else
    d compute domain records create "$DOMAIN" --record-type A --record-name "$1" \
      --record-data "$2" --record-ttl 300 >/dev/null
    info "A $1 -> $2"
  fi
}
add_a "@" "$PUBLIC_IP"
add_a "*" "$PUBLIC_IP"

# --- delegation gate (DNS-01 needs DO to be authoritative) -----------------
say "nameserver delegation"
# Query a public resolver: a local resolver may still cache the old delegation.
NS="$(dig +short NS "$DOMAIN" @1.1.1.1 2>/dev/null | tr '\n' ' ' || true)"
[ -n "$NS" ] || NS="$(dig +short NS "$DOMAIN" 2>/dev/null | tr '\n' ' ' || true)"
info "current NS: ${NS:-<none>}"
if ! printf '%s' "$NS" | grep -q 'digitalocean.com'; then
  cat <<EOF

The wildcard certificate uses DNS-01, so DigitalOcean must be authoritative for
$DOMAIN. At Namecheap, set the nameservers to:

    ns1.digitalocean.com
    ns2.digitalocean.com
    ns3.digitalocean.com

Then re-run:  pnpm deploy:do
EOF
  exit 0
fi

# --- remote: cert + edge ---------------------------------------------------
say "remote deploy"
# A recreated droplet reuses the reserved IP with a new host key.
ssh-keygen -R "$PUBLIC_IP" >/dev/null 2>&1 || true
info "copying deploy files"
ssh $SSH_OPTS "root@$PUBLIC_IP" "mkdir -p /srv/idfon-edge /etc/idfon-edge"
scp $SSH_OPTS "$DEPLOY/acme-issue.sh" "root@$PUBLIC_IP:/root/acme-issue.sh" >/dev/null
scp $SSH_OPTS "$DEPLOY/compose.yaml" "root@$PUBLIC_IP:/srv/idfon-edge/compose.yaml" >/dev/null

# Optional co-located iroh relay (issue #26).
COMPOSE_FILES="-f compose.yaml"
RELAY_ENV=""
if [ "$DEPLOY_RELAY" = "1" ]; then
  info "provisioning the co-located iroh relay"
  # Relay access (fail-closed). The relay handshake authenticates each
  # client's endpoint id (TLS key export) before the access hook runs, so
  # allowlist/callout decisions are trustworthy. No auth configured = refuse
  # to deploy, unless IDFON_RELAY_OPEN=1 deliberately requests an open relay.
  RELAY_CONFIG="$DEPLOY/relay/config.toml"
  ACCESS_LINE=""
  if [ -n "$RELAY_ALLOWLIST" ]; then
    ids="$(printf '%s' "$RELAY_ALLOWLIST" | tr ',' '\n' \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e 's/.*/"&"/' \
      | paste -sd ', ' -)"
    ACCESS_LINE="access = { allowlist = [$ids] }"
  elif [ -n "$RELAY_AUTH_URL" ]; then
    if [ -n "$RELAY_AUTH_TOKEN" ]; then
      ACCESS_LINE="access = { http = { url = \"$RELAY_AUTH_URL\", bearer_token = \"$RELAY_AUTH_TOKEN\" } }"
    else
      ACCESS_LINE="access = { http = { url = \"$RELAY_AUTH_URL\" } }"
    fi
  elif [ -n "$RELAY_TOKEN" ]; then
    ACCESS_LINE="access = { shared_token = [\"$RELAY_TOKEN\"] }"
  elif [ "${IDFON_RELAY_OPEN:-0}" = "1" ]; then
    ACCESS_LINE="access = \"everyone\""
  else
    die "refusing to deploy an unauthenticated relay: set IDFON_RELAY_ALLOWLIST, IDFON_RELAY_AUTH_URL, or IDFON_RELAY_TOKEN (or keep the token in ~/.idfon/relay-token), or pass IDFON_RELAY_OPEN=1 for an open relay"
  fi
  RELAY_CONFIG="$(mktemp)"
  awk -v line="$ACCESS_LINE" \
    '{ if ($0 ~ /^access = /) print line; else print }' \
    "$DEPLOY/relay/config.toml" > "$RELAY_CONFIG"
  ssh $SSH_OPTS "root@$PUBLIC_IP" "mkdir -p /srv/idfon-edge/relay"
  scp $SSH_OPTS "$RELAY_CONFIG" "root@$PUBLIC_IP:/srv/idfon-edge/relay/config.toml" >/dev/null
  [ "$RELAY_CONFIG" != "$DEPLOY/relay/config.toml" ] && rm -f "$RELAY_CONFIG"
  scp $SSH_OPTS "$DEPLOY/compose.relay.yaml" "root@$PUBLIC_IP:/srv/idfon-edge/compose.relay.yaml" >/dev/null
  COMPOSE_FILES="-f compose.yaml -f compose.relay.yaml"
  RELAY_ENV="IDFON_RELAY_URLS=https://relay.$DOMAIN:8443\n"
  if [ -n "$RELAY_TOKEN" ]; then
    RELAY_ENV="${RELAY_ENV}IDFON_RELAY_TOKEN=$RELAY_TOKEN\n"
  fi
fi

info "issuing wildcard certificate (DNS-01)"
ssh $SSH_OPTS "root@$PUBLIC_IP" \
  "DIGITALOCEAN_API_KEY='$TOKEN' sh /root/acme-issue.sh '$DOMAIN' '$EMAIL'"

info "starting idfon-edge"
ssh $SSH_OPTS "root@$PUBLIC_IP" \
  "printf 'IDFON_EDGE_IMAGE=%s\nIDFON_EDGE_DOMAIN=%s\n${RELAY_ENV}' '$EDGE_IMAGE' '$DOMAIN' > /srv/idfon-edge/.env
   cd /srv/idfon-edge && docker compose $COMPOSE_FILES pull -q && docker compose $COMPOSE_FILES up -d --remove-orphans"

# --- verify ----------------------------------------------------------------
say "verify"
healthy=0
for _ in $(seq 1 20); do
  # --resolve sidesteps a stale local resolver for the apex.
  if curl -fsS --resolve "$DOMAIN:443:$PUBLIC_IP" "https://$DOMAIN/healthz" >/dev/null 2>&1; then
    healthy=1; break
  fi
  sleep 6
done
if [ "$healthy" = "1" ]; then
  info "healthy: https://$DOMAIN/healthz"
else
  info "not healthy yet; logs:"
  info "  ssh root@$PUBLIC_IP 'cd /srv/idfon-edge && docker compose logs'"
fi

cat <<EOF

done.
  droplet:  $NAME ($DROPLET_ID)  $PUBLIC_IP
  image:    $EDGE_IMAGE
  health:   https://$DOMAIN/healthz
  logs:     ssh root@$PUBLIC_IP 'cd /srv/idfon-edge && docker compose logs -f'
EOF
