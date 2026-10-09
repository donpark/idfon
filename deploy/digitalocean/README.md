# idfon-edge on DigitalOcean (droplet)

The public `idfon.net` ingress (`docs/idfon-web-hybrid-plan.md`) as a single
DigitalOcean droplet running the existing `crates/idfon-edge` container. The
edge terminates TLS itself with a Let's Encrypt **wildcard** certificate
obtained through DigitalOcean DNS (DNS-01), so `<ref>.idfon.net` gives every
peer a clean origin.

```
https://<ref>.idfon.net/<path>   ->   idfon/http3/1 over iroh to peer <ref>
https://idfon.net/<ref>/<path>   (fallback)
```

`<ref>` is the peer's 64-hex endpoint id; there is no directory. TLS/DNS are
the host's job; the edge only needs outbound network (iroh relay + QUIC) and
inbound 443.

## Quick deploy (`pnpm deploy:do`)

`scripts/deploy-digitalocean.sh` provisions everything and is safe to re-run:
DNS zone, droplet + reserved IP, firewall, `@`/`*` A records, the wildcard
cert, and `docker compose up`.

```sh
cp deploy/digitalocean/.env.example deploy/digitalocean/.env   # set DIGITALOCEAN_API_KEY
pnpm deploy:do
```

It stops once at the **nameserver delegation** step if `idfon.net` still points
at Namecheap: set the NS to `ns1/ns2/ns3.digitalocean.com`, then run
`pnpm deploy:do` again. Everything else is automatic. The rest of this file is
the equivalent manual path.

## Enterprise: co-located iroh relay (#26)

Relay connectivity is **required** behind enterprise NAT: symmetric/CGNAT
usually defeats UDP hole-punching, and many networks allow only outbound TCP
443. `iroh-relay`'s WebSocket transport runs over `wss://…:8443`, so it
traverses that. Enable the co-located relay:

```sh
IDFON_DEPLOY_RELAY=1 IDFON_RELAY_TOKEN=<token> pnpm deploy:do
```

That starts `n0computer/iroh-relay:v1.3.0` beside the edge from
`relay/config.toml` + `compose.relay.yaml`, reusing the wildcard cert, serving
`8443/tcp` (WSS) and `7842/udp` (QUIC address discovery), and writes
`IDFON_RELAY_URLS=https://relay.<domain>:8443` into the edge's env. The firewall
already allows those two ports.

**Every peer must use the same relay** (a relay is a shared rendezvous): set
`IDFON_RELAY_URLS` / `IDFON_RELAY_TOKEN` on each daemon too. A peer left on N0
will not meet one on the enterprise relay.

Relay access — prefer a mode that needs **no client secret**:

- `IDFON_RELAY_ALLOWLIST=<id>,<id>` → the relay admits only those endpoint ids.
- `IDFON_RELAY_AUTH_URL=<url>` (+ optional `IDFON_RELAY_AUTH_TOKEN`) → the relay
  asks your auth service per connecting endpoint.
- `IDFON_RELAY_TOKEN=<token>` → shared bearer. Clients present it at **runtime**
  (app Relay settings / env), never compiled in; it cannot be revoked per device.

Clients are configured the same way: the iOS/mac apps have a **Relay** setting
(applied via `setenv`/subprocess env when the daemon starts), and CLI/native/eve
use the env vars.

## What you need

- A DigitalOcean account; `doctl` authenticated locally (or use the DO console).
- `idfon.net` added as a **DigitalOcean DNS zone** (recommended; the ACME
  DNS-01 script below uses the DO API), with Namecheap's nameservers pointed at
  `ns1/ns2/ns3.digitalocean.com`. Keeping the zone at Namecheap also works, but
  then use your provider's DNS API (`acme.sh --dns dns_namecheap`) instead.
- A DigitalOcean API token with write access, for the ACME DNS-01 challenge
  (exported as `DO_API_KEY` or `DIGITALOCEAN_API_KEY`; `acme-issue.sh` accepts
  either).
- The `idfon-edge` image (see "Get the image" below).

## 0. Get the image

**No paid GitHub plan is required.** GitHub Packages is free for *public*
packages (private ones have a plan-dependent quota), and GitHub Actions is free
for public repos. `donpark/idfon` is public, so GHCR works on a Free account.

`ghcr.io/donpark/idfon-edge` is built from `deploy/idfon-edge/Dockerfile` by
`.github/workflows/edge.yml`. It does not exist until that workflow pushes it
for an `edge-v*` tag:

```sh
git tag edge-v0.8.0
git push origin edge-v0.8.0
```

That publishes `:edge-v0.8.0` and `:latest`. New GHCR packages default to
private, so make it public once: GitHub → Packages → `idfon-edge` → Package
settings → Change visibility → Public. Public packages cost nothing to store or
pull. (To keep it private instead, log the droplet in with a classic PAT that
has `read:packages`: `ssh root@<ip> 'docker login ghcr.io -u donpark
--password-stdin' < pat.txt` — private quota then applies.)

Alternative: **DigitalOcean Container Registry** has a free Starter plan
(1 registry, 1 repository, 500 MiB), enough for this image. With `doctl`:

```sh
doctl registry create idfon
doctl registry login
docker tag idfon-edge registry.digitalocean.com/idfon/idfon-edge:latest
docker push registry.digitalocean.com/idfon/idfon-edge:latest
```

Then set `IDFON_EDGE_IMAGE=registry.digitalocean.com/idfon/idfon-edge:latest`
in `.env` (and `doctl registry login` on the droplet so it can pull).

## 1. Droplet

1 vCPU / 1 GB (or 2 GB) Ubuntu 24.04 is enough for an MVP. Add a **Reserved
IP** so the DNS records survive a rebuild. Paste `cloud-init.yaml` as user
data (installs Docker, creates `/srv/idfon-edge` for the identity key).

After it boots, verify:

```sh
ssh root@<reserved-ip> docker --version
```

## 2. Firewall

Inbound `443` (edge), `80` (optional; ACME uses DNS-01, not HTTP-01), `22` from
your IP; outbound all. With `doctl`:

```sh
doctl compute firewall create --name idfon-edge \
  --inbound-rules "protocol:tcp,ports:443,address:0.0.0.0/0 protocol:tcp,ports:80,address:0.0.0.0/0 protocol:tcp,ports:22,address:<your-ip>/32" \
  --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0 protocol:udp,ports:all,address:0.0.0.0/0 protocol:icmp,address:0.0.0.0/0" \
  --droplet-ids <droplet-id>
```

## 3. DNS

```sh
doctl compute domain create idfon.net
doctl compute domain records create idfon.net --record-type A --record-name @   --record-data <reserved-ip> --record-ttl 300
doctl compute domain records create idfon.net --record-type A --record-name '*' --record-data <reserved-ip> --record-ttl 300
```

Add the `AAAA` records too if the droplet has IPv6. Point Namecheap at the DO
nameservers reported by `doctl compute domain records list idfon.net`.

**Copy existing records first.** Moving nameservers transfers authority for
*all* records, so recreate any mail records in the DO zone before switching NS
or email stops. Namecheap free email forwarding, for example:

```sh
# MX @ -> eforward1/2/3.registrar-servers.com (10), eforward4 (15), eforward5 (20)
#   (DO requires MX data to end with a dot)
# TXT @ -> v=spf1 include:spf.efwd.registrar-servers.com ~all
doctl compute domain records create idfon.net --record-type MX --record-name @ \
  --record-data eforward1.registrar-servers.com. --record-priority 10
# ...and the SPF TXT.
```

## 4. Wildcard TLS (DNS-01)

DigitalOcean Load Balancers can issue a managed wildcard certificate, but that
adds $12–15/mo; on a bare droplet the cert is a one-time `acme.sh` setup with
automatic renewal (acme.sh installs a cron job):

```sh
scp deploy/digitalocean/acme-issue.sh root@<reserved-ip>:/root/
ssh root@<reserved-ip> 'DIGITALOCEAN_API_KEY=dop_v1_... sh /root/acme-issue.sh idfon.net admin@idfon.net'
```

This installs `*.idfon.net` + apex to `/etc/idfon-edge/{cert,key}.pem` and
chowns them to the container's uid (10001). The edge **re-reads the cert/key
when either mtime changes**, so renewal needs no restart.

## 5. Run the edge

```sh
scp deploy/digitalocean/compose.yaml deploy/digitalocean/.env.example root@<reserved-ip>:/srv/idfon-edge/
ssh root@<reserved-ip>
cd /srv/idfon-edge && cp .env.example .env   # edit if needed
docker compose up -d
docker compose logs -f
```

The edge prints an owner pairing block and its endpoint id on first start. With
the default `--require-ticket resource.read`, no pairing is needed: mint a
scoped ticket and hand it to the requester.

## 6. Verify

```sh
curl https://idfon.net/healthz                     # -> ok
curl https://idfon.net/<peer-ref>/fs/index.html    # 401 without a ticket
# with the ticket the owner just minted:
idfon access ticket --subject requester --capability resource.read \
  --path-scope /fs/public --expires-at $(( $(date +%s) + 86400 ))
curl -H 'x-idfon-ticket: <ticket>' https://<peer-ref>.idfon.net/fs/public/hello.txt
docker compose logs | grep idfon.edge.access       # one line per served request
```

Point a DigitalOcean Uptime check at `https://idfon.net/healthz`.

## Auth and usage

- Default: `--require-ticket resource.read`; the ticket is verified at the edge
  and forwarded (`x-idfon-ticket`), and the peer authorizes the issuer.
- `--token VALUE` (or `IDFON_EDGE_TOKEN`) switches to a shared bearer token.
- `--rate-limit` is per authenticated subject per minute.
- iOS/macOS requesters set the edge URL + ticket in the app's Edge settings, or
  use `idfon web open <ref>/<path>`.

## Operate

- **Identity**: `/srv/idfon-edge/edge.key` (persistent). Back it up; it is what
  option-A grants and edge pairing bind to. Or set `IDFON_EDGE_KEY` (64 hex) in
  `.env` and drop the mount.
- **Upgrade**: `docker compose pull && docker compose up -d`.
- **Cert renewal**: acme.sh's cron; check with
  `ssh root@<ip> '~/.acme.sh/acme.sh --cron'`.
- **Backups**: enable DO weekly droplet backups, or back up `/srv/idfon-edge`.

## Troubleshooting

- `certificate signed by unknown authority` in the edge log on startup: the
  cert files are missing or unreadable by uid 10001 — re-run `acme-issue.sh`.
- `dial ERR`/`upstream unavailable` (502): the resource peer is offline or
  unreachable; verify it is online and that outbound UDP/TCP is allowed.
- `<ref>.idfon.net` resolves but the edge returns 404: the ref is not a 64-hex
  endpoint id, or DNS does not include the `*` record.
