#!/bin/sh
# Issue/renew the idfon.net wildcard certificate with acme.sh + DigitalOcean
# DNS (DNS-01) and install it for the edge container.
#
#   DO_API_KEY=dop_v1_... sh acme-issue.sh [domain] [email]
#
# acme.sh registers a cron/systemd timer, so renewal is automatic. The edge
# re-reads the certificate when its mtime changes; no restart is needed.
set -eu

DOMAIN="${1:-idfon.net}"
EMAIL="${2:-admin@idfon.net}"
# Accept the common DigitalOcean token variable names; acme.sh's dns_dgon reads
# only DO_API_KEY, so normalize into that.
DO_API_KEY="${DO_API_KEY:-${DIGITALOCEAN_API_KEY:-${DIGITALOCEAN_ACCESS_TOKEN:-${DO_TOKEN:-}}}}"
: "${DO_API_KEY:?set DO_API_KEY (or DIGITALOCEAN_API_KEY / DIGITALOCEAN_ACCESS_TOKEN) to a DigitalOcean API token with write access to the zone}"
export DO_API_KEY

# The idfond-edge image runs as uid 10001; the key must be readable by it.
EDGE_UID="${EDGE_UID:-10001}"
CERT_DIR="${CERT_DIR:-/etc/idfon-edge}"

ACME="${ACME:-$HOME/.acme.sh/acme.sh}"
if [ ! -x "$ACME" ]; then
  echo "installing acme.sh for $EMAIL"
  curl -fsSL https://get.acme.sh | sh -s "email=$EMAIL"
fi

# acme.sh returns 2 when the existing cert is still valid ("Skipping");
# that is success for our purposes, so do not treat it as an error.
set +e
"$ACME" --issue --dns dns_dgon -d "$DOMAIN" -d "*.$DOMAIN" --keylength ec-256
status=$?
set -e
if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
  echo "acme.sh --issue failed (exit $status)" >&2
  exit "$status"
fi

install -d -m 0755 "$CERT_DIR"
"$ACME" --install-cert -d "$DOMAIN" --ecc \
  --fullchain-file "$CERT_DIR/cert.pem" \
  --key-file "$CERT_DIR/key.pem" \
  --reloadcmd "chown $EDGE_UID:$EDGE_UID '$CERT_DIR/key.pem' && chmod 600 '$CERT_DIR/key.pem' && chmod 644 '$CERT_DIR/cert.pem'"

echo "installed $DOMAIN + *.$DOMAIN to $CERT_DIR"
