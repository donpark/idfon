# idfon.net edge on Cloudflare Workers

The public `idfon.net` ingress (`docs/idfon-edge.md`) as a
Cloudflare Worker. It replaces the native `crates/idfon-edge` process for the
public edge: Cloudflare terminates TLS and owns the wildcard origin, the Worker
authenticates the requester, and fetches the resource from the owner peer over
`idfon/http3/1` (iroh → relay → QUIC → H3). There is no certificate file and no
host to run.

```
https://<ref>.idfon.net/<path>   (wildcard route -> this Worker)
https://idfon.net/<ref>/<path>   (fallback)
```

`<ref>` is the peer's 64-hex endpoint id; there is no directory.

## Why this works on Workers (and the two quirks)

iroh 1.3 supports `wasm32-unknown-unknown` with a relay (WebSocket) transport
and `n0-future`; `iroh-h3-client` is wasm-aware. On `workerd` specifically:

1. **Trailing-dot hostnames are rejected.** iroh's default relay URLs (and the
   relay URL a peer publishes) are absolute DNS names (`...iroh.link.`).
   `workerd` returns `internal error` for these in both `fetch` and `WebSocket`.
   `src/lib.rs` normalizes every relay URL (the local relay map and resolved
   peer addresses via `NormalizingLookup`) to drop the trailing dot. Without
   this, `endpoint.online()`/dialing hang.
2. **`ring` must be archived with LLVM `ar` on macOS.** BSD `ar` produces an
   empty archive for wasm objects, so the link fails with undefined
   `ring_core_*` symbols. `build.sh` sets `AR_wasm32_unknown_unknown`.

Consequences: the Worker is **relay-only** (no direct/UDP), and it builds a
fresh iroh endpoint **per request** (Workers may drop the isolate's sockets
between requests; a cached endpoint reuses a dead relay WebSocket and hangs).
Expect ~1 s per cold request. If that becomes a bottleneck, move the endpoint
into a Durable Object.

## Cloudflare policy and limits (checked 2026-10-08)

**The ToS is the gating item, not the tech.** The Self-Serve Subscription
Agreement §2.2.1(j) forbids using the Services "to provide a virtual private
network or other similar proxy services." That clause applies to Cloudflare's
Services generally, so it is not specific to Workers — a native edge behind
Cloudflare's proxy carries the same exposure. An ingress that relays
third-party peer traffic (the plan's own words: "a relay, not an authority")
plausibly reads as a proxy service. This needs an explicit decision before
pointing `idfon.net` at it:

- get written confirmation from Cloudflare (account team or
  `abuse@cloudflare.com`) that the idfon edge is acceptable; or
- keep the edge off Cloudflare's proxy (DNS-only, grey-cloud) and terminate TLS
  on a host you control; or
- scope the public edge to the owner's own resources / known peers so it is
  plainly an application gateway, not an open proxy.

Other rules that were checked:

- §2.2.1(a) prohibits selling third-party access to the Services; keep the
  public edge free and not a general-purpose HTTP proxy (it only speaks
  `<ref>` → `idfon/http3/1`).
- The old "Limitation on Serving Non-HTML Content" (§2.8) is **gone** from the
  current agreement. The remaining video/large-file rule is in the CDN
  service-specific terms and points at the paid Developer Platform (Workers)
  as the allowed path.
- The Developer Platform service-specific terms add content responsibility and
  "no undue burden", but no additional proxy prohibition.
- WebSocket proxying is explicitly supported (the Workers WebSockets API
  documents `allowHalfOpen` "for WebSocket proxying").
- `connect()`/TCP is available; only port 25 is prohibited (irrelevant here).

Operational limits that shape the deployment:

| Limit | Free | Paid | Impact |
| --- | --- | --- | --- |
| CPU per request | 10 ms | 30 s default | iroh's QUIC/TLS handshake on wasm almost certainly exceeds 10 ms CPU. **Use a paid plan.** |
| Requests | 100k/day | unlimited | public ingress needs paid. |
| Subrequests | 50 | 10,000 | we make 1 (pkarr). |
| Simultaneous outgoing connections | 6 | 6 | we use 1 relay WebSocket; outbound WebSockets count while waiting for headers. |
| Wall time (HTTP) | unlimited | unlimited | no hard timeout while the client is connected. |
| Worker size | 64 MiB | 64 MiB | bundle is 4.9 MB raw / 1.6 MB gzip. |
| Startup | 1 s | 1 s | 4.9 MB wasm; watch cold starts. |

Routing:

- **Wildcard ingress must use Routes, not Custom Domains** — Custom Domains do
  not support wildcard DNS records. A Route needs an active zone, the Worker,
  and a **proxied** DNS record for the hostname.
- Universal SSL covers the apex and one level of subdomain, so `*.idfon.net`
  is covered without Advanced Certificate Manager; `<ref>.idfon.net` is one
  level.

## Prerequisites

- A Cloudflare account with the `idfon.net` zone active (nameservers set at
  Namecheap to the two Cloudflare-assigned NS).
- `worker-build` (`cargo install worker-build`), `wrangler` (`npx wrangler`),
  and on macOS LLVM (`brew install llvm`) for `llvm-ar`.

## Deploy

```sh
cd deploy/cloudflare
npm install                      # wrangler
./build.sh                       # -> build/worker/shim.mjs

npx wrangler secret put EDGE_KEY # 64 hex ed25519, persistent edge identity
# or use shared bearer auth instead:
# npx wrangler secret put EDGE_TOKEN

npx wrangler deploy
```

`EDGE_KEY` is optional in ticket mode (the peer authorizes the ticket issuer,
not the edge). It is required for the option-A flow where the owner grants the
edge `resource.read`. Generate it with `idfon` identity tooling or
`openssl rand -hex 32`.

### DNS / TLS

Cloudflare terminates TLS with Universal SSL, which already covers `idfon.net`
and `*.idfon.net` once the zone is active. For the Worker route to be invoked,
Cloudflare needs a **proxied** DNS record for the hostnames, so add placeholder
records (proxied, "Proxied" on). Custom Domains cannot be used for the wildcard
(they do not support wildcard DNS records):

- `A` `@` → `100::`
- `AAAA` `*` → `100::`

Then the `routes` in `wrangler.toml` (`*.idfon.net/*`, `idfon.net/*`) attach.
No origin is contacted — the Worker is the origin.

## Local development

```sh
./build.sh
printf 'EDGE_REQUIRE_TICKET = "resource.read"\n' > .dev.vars   # or EDGE_TOKEN
npx wrangler dev
curl -H 'x-idfon-ticket: <ticket>' http://localhost:8787/<ref>/
```

Routes in `wrangler.toml` are ignored by local `wrangler dev`; use the
`/<ref>/<path>` form. Test against a real peer (`scripts/edge-e2e.sh` starts a
native provider) or a trivial `iroh-h3-axum` echo server.

## Auth and limits

- Ticket (default): `x-idfon-ticket` header, `idfon_ticket` cookie, or
  `?ticket=`; signature/expiry/capability are verified and the raw ticket is
  forwarded so the peer authorizes the issuer (P3).
- Token: `EDGE_TOKEN` + `Authorization: Bearer <token>` or `?token=`.
- `RATE_LIMIT` is per authenticated subject per minute, **per isolate** — best
  effort, not global. Use Cloudflare's Rate Limiting rules for a hard limit.
- `/healthz` answers before auth; a 64-hex ref that cannot be resolved/dialed
  yields `502`.

## Not in this crate

Durable Object endpoint caching, `/metrics` (use Cloudflare analytics), and
per-IP rate limiting.
