# idfon web: hybrid gateway architecture — implementation plan

> **Status:** design (P0 skeleton landed in `crates/idfon-edge`; P1–P5 not
> implemented). Companion to `idfon-web.md`, which analyses serving P2P pages
> in a `WKWebView`; this plans the **hybrid transport** that analysis closes
> with. Written 2026-10-07.

`idfon-web.md` ends on a three-tier hybrid: a public `https://idfon.net` gateway
as ingress, an on-device adapter, and the iroh swarm as backbone — with a
direct-first/relay-fallback policy, a control/data-plane split, and iOS
background handoff. This document plans that transport. The WebMCP /
app-owned-JSON-render layer in the earlier sections is the *consumer* of it, not
part of the transport.

## Scope

Three cooperating layers:

1. **Edge gateway** — `https://idfon.net/<ref>/<path>` (or
   `https://<ref>.idfon.net/<path>`): a public, always-on **idfon peer** that
   terminates HTTPS and bridges to `idfon/http3/1` over iroh. It replaces the
   local loopback listener for anything a `WKWebView` must fetch: standard
   TLS, background-safe, NAT-proof.
2. **On-device adapter** — the app talks iroh natively (already true: the daemon
   + `idfon-client`); a loopback HTTP surface exists only to feed a WebView,
   never as the app's own API.
3. **P2P swarm** — the actual transport; direct connections preferred.

Three patterns and three constraints from the analysis are in scope: primary +
relay fallback, control/data-plane split, smart gateway bridging; route-state
sync, authorization verified at **both** ends, and iOS background handoff.

## Footholds and gaps

| Piece | State |
| --- | --- |
| `idfon://` addressing, `account_alias` handle, `AccountResolver` | landed (`crates/idfon-gateway`) |
| H3-over-iroh client + server, ALPN `idfon/http3/1` | landed (`crates/idfon-h3`) |
| Loopback gateway (`Backend`/`Authorizer`) + `IrohBackend` (H3 GET) | landed (`crates/idfon-gateway`) |
| Per-identity provider, `resource.read` grant, `gateway.start`/`provider.start` | landed (`crates/idfon-daemon`) |
| Standalone provider | landed (`idfon-mcp expose`) |
| Edge service (`idfon.net`) | **P0 skeleton** (`crates/idfon-edge`) |
| Wildcard origin / TLS / URL mapping | not implemented |
| Requester identity auth (gateway token is one shared secret; `Authorizer` sees only `account, path`) | not implemented |
| Ticket-over-H3 (transparent edge, path-scoped) | not implemented |
| Client direct-first → edge fallback | not implemented |
| iOS background handoff to the edge | not implemented |
| App-owned JSON-render / WebMCP registry | not implemented (artifacts model already anticipates `json-render` metadata + a sandboxed WebView) |

The two hard parts are **edge identity/auth** and **H3 request
authorization**: `authorize_resource_read` (`crates/idfon-daemon/src/lib.rs`)
maps the *QUIC peer endpoint id* to a known peer with a `resource.read` grant,
so today an edge cannot carry an end-user's authority across.

## Target topology

```
 Browser / WKWebView / curl
        │  HTTPS  https://<ref>.idfon.net/<path>   (+ requester token)
        ▼
 ┌──────────────── idfon.net edge (crates/idfon-edge) ────────┐
 │ TLS (wildcard) → virtual host → account ref                 │
 │ AuthZ: verify requester token, rate-limit, block open relay │
 │ iroh endpoint (persistent identity, always-on peer)         │
 │ IrohBackend: GET over idfon/http3/1  ──────────────┐        │
 └────────────────────────────────────────────────────┼────────┘
                                                       ▼
        app (direct-first)  ── idfon/http3/1 ──▶  resource-owner peer
        idfond + provider (Documents/Shared, resource.read)
```

## Authorization — decide first

- **A. Edge-as-known-peer (P0, shipped skeleton):** the owner pairs with the
  edge endpoint id and grants it `resource.read`, like a paired channel. No
  protocol change. Cost: per-owner grant, root-wide scope, the edge sees all
  traffic.
- **B. Ticket-over-H3 (correct end state):** the requester's own capability
  ticket rides the H3 request (new header, e.g. `Authorization: IDFON-TICKET`);
  the peer authorizes the **ticket issuer** instead of the QUIC peer. The edge
  becomes transparent and per-path scoping follows from the grant. Requires an
  `idfon-h3` server change, an `authorize_resource_read` change, and gateway
  client support.
- **C. Edge-minted scoped token:** the edge pairs with the owner and mints
  short-TTL, path-scoped tokens. Middle ground; still edge-trusted.

Recommendation: **A for P0–P1, B for P3**, with the grant extensible to a path
prefix. Either way `idfon-gateway` needs the same API change:
`Authorizer`/`Backend` must see a verified **caller context** (token claims),
not just `(account, path)`.

## Phases

### P0 — edge skeleton (landed)

- `crates/idfon-edge`: binary with a persistent iroh identity (key file), a
  `--bind`/`--token`/`--key-file`/`--allow` surface, and dispatch through
  `idfon_gateway::serve` with `IrohBackend`.
- Resolver: `EndpointRefResolver` maps a 64-hex `<ref>` to `EndpointAddr` via
  N0 discovery (`EndpointAddr::new(id)`), with optional pinned addresses and an
  allow-list.
- Policy: the bearer token is the requester boundary (the gateway enforces it);
  the authorizer admits every resolved account. Path scoping is P3.
- No TLS yet: run the gateway on loopback behind a TLS reverse proxy, or add a
  `rustls` listener in P1 (keep `idfon-gateway` loopback-first).
- Tests: `crates/idfon-edge/tests/edge_e2e.rs` — a peer serves a grant-gated
  router over H3; the edge fetches it over HTTP and returns the body; token and
  allow-list paths are asserted.

### P1 — URL, TLS, requester auth

- `*.idfon.net` wildcard DNS + certificate; `<ref>.idfon.net` → account
  (virtual host, matching the gateway's existing form); keep
  `idfon.net/<ref>/<path>` as the no-wildcard fallback.
- Replace `Config.token: Option<String>` with a verifier (signed token or
  capability ticket) and pass claims into `Authorizer` as a caller context.
- Pairing flow so an owner grants the edge endpoint id `resource.read` (CLI and
  both apps), plus ops: Dockerfile, systemd unit, `/healthz`, per-IP/per-token
  rate limit, metrics.

### P2 — on-device adapter (mostly exists)

- No new loopback listener for the app API; the daemon + `idfon-client` are the
  adapter.
- Add the **direct-first → edge fallback** selector: try direct H3 to the peer,
  on timeout/NAT-block retry the edge URL; cache `EndpointAddr` with a TTL.
- New daemon RPC / CLI: `idfon web open <ref>/<path>` and
  `idfon fetch --prefer direct|edge`.

### P3 — ticket-over-H3 (transparent edge, path-scoped)

- `crates/idfon-h3`: accept a caller capability ticket on inbound requests.
- `authorize_resource_read`: accept ticket issuer + subject and a path prefix,
  not only the QUIC peer.
- Gateway/edge client attaches the requester ticket; `idfon-protocol` gains the
  scoped form.

### P4 — WebView + background handoff

- Apps' sandboxed WebView loads the edge HTTPS URL (public cert, so no
  `WKNavigationDelegate` trust bypass) or the local `.localhost` proxy for the
  offline-only mode.
- iOS: background `URLSession` to the edge; the edge keeps the iroh session
  alive past app suspension; reconcile on foreground. This is the part only the
  edge makes possible.

### P5 — web layer (optional for this plan)

- App-owned `json-render` component catalog + an action dispatcher whose actions
  are MCP tools; hard limits (size/depth), strict CSP/HSTS from the edge, a
  human-in-the-loop prompt for destructive tools, and minimal
  `WKScriptMessageHandler` exposure.

## Open decisions

1. **Edge runtime** — new Rust crate in this repo, or a Cloudflare Worker (iroh
   JS)? The repo has no `idfon.net` code and no JS iroh binding here; Rust reuses
   `idfon-gateway`/`idfon-h3` directly.
2. **URL form** — wildcard subdomain (clean origins, needs wildcard TLS) vs
   path.
3. **Privacy posture** — self-hostable edge? opt-in? The edge inherently breaks
   the "no directory / no public endpoint" property.
4. **Auth timeline** — is P3 required for v1, or is the per-owner grant (A)
   acceptable?

## Verification

- `cargo test -p idfon-edge` (edge e2e), `cargo test -p idfon-gateway`
  (H3 backend), `cargo check --workspace --all-targets`.
- Manual: start a provider (`idfon-mcp expose --root DIR`), pair the edge, and
  fetch `https://<peer>.idfon.net/fs/<path>` from a browser and from a `WKWebView`
  on device (background the app mid-fetch in P4).
