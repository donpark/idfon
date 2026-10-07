# idfon-edge

The public-ingress half of the hybrid web architecture
(`docs/idfon-web-hybrid-plan.md`): a long-running, always-on idfon peer that
terminates HTTP(S) for a consumer (a `WKWebView`, a browser, `curl`) and bridges
each request to a resource-owner peer over `idfon/http3/1`.

```
https://<ref>.<domain>/<path>   ->   GET <path> to the peer behind <ref>
https://<domain>/<ref>/<path>   ->   same, no-wildcard fallback
```

`<ref>` is the peer's endpoint id (64 hex); there is no directory.

## Run (loopback / development)

```sh
cargo run -p idfon-edge -- --bind 127.0.0.1:8080 --key-file ~/.idfon/edge.key
curl -H 'Authorization: Bearer <token>' http://127.0.0.1:8080/<peer-id>/fs/readme.txt
```

## Run (public, e.g. `idfon.net`)

The code is ready; the deployment is external. You need:

1. A public host and **wildcard DNS** `*.idfon.net` (plus `idfon.net`).
2. A **TLS certificate** covering both (`*.idfon.net`), or TLS terminated by a
   reverse proxy (Caddy/Cloudflare) in front of a loopback bind.
3. A requester credential and a rate limit:

```sh
idfon-edge \
  --bind 0.0.0.0:8443 --domain idfon.net \
  --tls-cert /etc/idfon/cert.pem --tls-key /etc/idfon/key.pem \
  --require-ticket resource.read --rate-limit 120 \
  --key-file /var/lib/idfon/edge.key
```

`--require-ticket resource.read` verifies a capability ticket (`x-idfon-ticket`
header, `idfon_ticket` cookie, or `?ticket=`) and forwards it to the peer, which
authorizes the ticket's **issuer** (P3). `--token VALUE` is the simpler shared
bearer alternative. `--health-path` (default `/healthz`) answers probes before
auth.

The edge prints an owner **pairing** block at startup: either pair with the
edge endpoint id and grant it `resource.read` (option A), or issue the requester
a path-scoped `resource.read` ticket with `idfon access`/`capability.ticket`
(option B; no pairing required).

## Not in this crate

DNS, certificate issuance, process supervision, and the TLS reverse proxy. Behind
a proxy, keep `--bind 127.0.0.1:8080` and let the proxy terminate TLS.
