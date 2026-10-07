# idfon web: hybrid gateway architecture — implementation plan

> **Status:** design (P0–P5 landed in `crates/idfon-*` and iOS).
> Companion to `idfon-web.md`, which analyses serving P2P pages in a
> `WKWebView`; this plans the **hybrid transport** that analysis closes with.
> Written 2026-10-07.

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
| Edge service (`idfon.net`) | **P0+P1** (`crates/idfon-edge`): persistent identity, TLS, `<ref>.<domain>` hosts, requester auth, health, rate limit |
| Wildcard origin / URL mapping | **P1:** origin-domain virtual hosts + TLS termination landed; wildcard DNS is external |
| Requester identity auth + caller context in `Authorizer`/`Backend` | **P1/P3:** `Authenticator`/`Caller` (with a forwarded `ticket`) landed |
| Ticket-over-H3 (transparent edge, path-scoped) | **P3:** `CapabilityTicket.path_scope`; provider accepts `x-idfon-ticket`; edge forwards it |
| Client direct-first → edge fallback | **P2:** `FallbackBackend` + `EdgeBackend` in `idfon-gateway`; daemon `prefer` + `IDFON_EDGE_URL`; `idfon fetch --prefer` |
| iOS background handoff to the edge | **P4:** `EdgeClient` background `URLSession` + inbox/reconcile; `fetchResource` direct→edge; `AppDelegate` handlers |
| App-owned JSON-render / tool registry | **P5:** `JSONRenderModel`/`JSONRenderView` + `RenderToolRegistry`; structured artifacts render natively |

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

Recommendation: **A for P0–P1, B for P3** (both landed; P3 uses owner-issued
bearer tickets with `path_scope` rather than a grant-side path). Either way
`idfon-gateway` needed the same API change: `Authorizer`/`Backend` see a
verified **caller context**, not just `(account, path)`.

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

- **Landed:** `idfon-gateway` takes an `Authenticator` and hands a verified
  `Caller` to `Authorizer` (`StaticToken` preserves the loopback behavior);
  `Config.origin_domain` accepts `<ref>.<domain>` virtual hosts; `Config.tls`
  terminates HTTPS (rustls, explicit `aws-lc-rs` provider); `Config.health_path`
  answers probes before auth. `idfon-edge` gained `EdgeAuth::{Open,Token,Ticket}`
  (`CapabilityTicketAuth` verifies a ticket whose subject is the edge endpoint id
  and whose capability is `web.fetch`, making the issuer the caller), a per-caller
  fixed-window rate limit, `--tls-cert/--tls-key`, `--health-path`, `--rate-limit`,
  and a printed owner pairing block (`peer add` + `access allow resource.read`).
- Remaining: `*.idfon.net` wildcard DNS + certificate issuance (the only
  external piece); operators run `idfon-edge --domain idfon.net
  --tls-cert --tls-key` behind that DNS.

### P2 — on-device adapter

- **Landed:** `idfon-gateway` gained `FallbackBackend` (direct-first; a
  definitive 404 is not retried) and `EdgeBackend` (`GET <base>/<ref><path>`
  with an opaque auth header). The daemon's loopback gateway takes a `prefer`
  param (`auto`|`direct`|`edge`), reads `IDFON_EDGE_URL` / `IDFON_EDGE_TOKEN` /
  `IDFON_EDGE_TICKET`, and rebuilds the gateway when the preference changes;
  `idfon fetch --prefer …` passes it through.
- Also landed: `idfon web open <ref>/<path>` (daemon `web.url` composes
  `<base>/<ref><path>` from `IDFON_EDGE_URL`), and a 30 s TTL cache for resolved
  `EndpointAddr`s in `IrohBackend`.

### P3 — ticket-over-H3 (transparent edge, path-scoped)

- **Landed:** `CapabilityTicket.path_scope: Option<String>` (signed only when
  set, so legacy tickets verify); `issue_capability_ticket_scoped`. `Caller`
  carries the raw `ticket`; `Backend::fetch` takes `&Caller`, and `IrohBackend`
  / `EdgeBackend` forward it as `x-idfon-ticket` over H3. The daemon provider
  accepts the header and authorizes a valid, unexpired ticket **issued by this
  peer** (bearer) with `resource.read` and a `path_scope` covering the request,
  falling back to the QUIC-peer grant when absent. The edge no longer requires
  `subject == edge`; it verifies signature/expiry/capability and forwards the
  ticket unchanged.

### P4 — WebView + background handoff

- **Landed (iOS):** `EdgeClient` holds the edge config (`-edgeurl` /
  `-edgeticket`, persisted in `UserDefaults`), fetches through the edge in the
  foreground, and starts a **background `URLSession`** download whose bytes are
  staged in `Idfon/edge-inbox` and drained on foreground. `DaemonClient.fetchResource`
  tries the loopback gateway (direct P2P) first, then the edge; the artifact
  detail's remote view uses it. `AppDelegate` installs the
  `handleEventsForBackgroundURLSession` handler and reconciles in
  `applicationWillEnterForeground`; `UIBackgroundModes` gains `fetch`.
- Also landed: the edge accepts the ticket from an `idfon_ticket` cookie (or
  `?ticket=`) as well as the header; iOS `EdgeWebView` injects the cookie into a
  non-persistent `WKWebView`, and `SceneDelegate` routes `.resource` there. The
  edge percent-decodes cookie/query values.
- Also landed: artifacts whose content is a peer shared-root path render by
  loading the **gateway URL** in the sandboxed web view (`ArtifactGateway` →
  loopback gateway first, public edge second) instead of injecting bytes, so
  relative subresources resolve; local cached/blob artifacts still inject.
- The artifact screen consumes reconciled bytes: while a remote load is in
  flight it starts an `EdgeClient.fetchInBackground` on
  `didEnterBackgroundNotification` (and on a failed fetch), and on
  `idfonEdgeReconciled` renders the matching `(account, path, Data)` record.
  `drainInbox` posts the records with their bytes; a screen that is gone drops
  them (the fetch is live, deliberately not cached).

### P5 — app-owned JSON-render + tool actions

- **Landed:** `ios/Idfon/JSONRenderModel.swift` holds the spec/`JSONValue`
  model, the fixed component catalog, size/element/depth limits, and
  `normalized()` (drops unknown component types with their subtrees, missing
  child ids, and cycles). `RenderToolRegistry` is the trusted action catalog —
  an unregistered action never runs and a `sensitive` tool needs a human
  confirmation. `JSONRenderView` draws the UIKit catalog (Text/Card/Row/Metric/
  Button/Divider/Spacer); `RenderTools` registers the idfon tools
  (`status`/`peers`, plus a sensitive `message.send`). A structured artifact is
  rendered as json-render when it parses as a spec, else the text view. Host
  check: `ios/Checks/JSONRenderCheck`.
- No `WKScriptMessageHandler` and no remote scripts by design: the agent
  supplies data, the app owns every component and action. The gateway adds
  `nosniff` / `Referrer-Policy` / a framing CSP to every response and HSTS over
  TLS; every action dispatch (with its outcome, including denials) is appended
  to `Idfon/action-audit.ndjson` by `ActionAudit`.

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
