# idfon web: hybrid gateway architecture — implementation plan

> **Status:** design (P0–P5 landed in `crates/idfon-*` and iOS; P6 is the
> Cloudflare Worker edge in `deploy/cloudflare`, source-landed, deploy pending).
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
| Edge on Cloudflare Workers | **P6** (`deploy/cloudflare`): the same ingress compiled to `wasm32-unknown-unknown` for `workerd`; relay-only, per-request endpoint |
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
  terminates HTTPS (rustls, explicit `aws-lc-rs` provider; cert/key are
  re-read on mtime change, so a rotation needs no restart); `Config.health_path`
  answers probes before auth. `idfon-edge` gained `EdgeAuth::{Open,Token,Ticket}`
  (`CapabilityTicketAuth` verifies a ticket's signature/expiry/capability and
  forwards it; P1 also required `subject == edge`, which **P3 removed** — see
  Deferred), a per-caller
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
  accepts the header and authorizes a valid, unexpired `resource.read` ticket
  with a `path_scope` covering the request — issued by this peer (bearer) **or
  by a peer this peer granted `resource.read`** — falling back to the QUIC-peer
  grant when absent. The edge no longer requires
  `subject == edge`; it verifies signature/expiry/capability and forwards the
  ticket unchanged. `idfon access ticket --path-scope <prefix>` exposes the
  scoped issue path; the gateway maps a peer's 403 to 403
  (`GatewayError::Forbidden`) so a scope refusal is not flattened into a 502.

### P4 — WebView + background handoff

- **Landed (iOS):** `EdgeClient` holds the edge config (`-edgeurl <url>
  <ticket>`, or `-edgeurl <url> -edgeticket <ticket>`, persisted in
  `UserDefaults`), fetches through the edge in the foreground, and starts a
  **background `URLSession`** download whose bytes are staged in
  `Idfon/edge-inbox` and drained on foreground. `DaemonClient.fetchResource`
  tries the loopback gateway (direct P2P) first, then the edge; the artifact
  detail's remote view uses it. `AppDelegate` installs the
  `handleEventsForBackgroundURLSession` handler (recreating the session so a
  cold-start relaunch can receive the finished download), and
  `SceneDelegate.sceneWillEnterForeground` drains the inbox — the app is
  scene-based, so `AppDelegate.applicationWillEnterForeground` never fires.
  `UIBackgroundModes` gains `fetch`; the download delegate stages only a `200`
  (an error body is not an artifact).
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
  rendered as json-render when `metadata.renderer == "json-render"` or (legacy)
  when it parses as a spec, else the text view. The mac AppKit port shares the
  model and `RenderTools`; `JSONRenderView` is NSStackView-based. Host check:
  `ios/Checks/JSONRenderCheck`.
- No `WKScriptMessageHandler` and no remote scripts by design: the agent
  supplies data, the app owns every component and action. The gateway adds
  `nosniff` / `Referrer-Policy` / a framing CSP to every response and HSTS over
  TLS; every action dispatch (with its outcome, including denials) is appended
  to `Idfon/action-audit.ndjson` by `ActionAudit` (rotated to a single `*.1`
  file at 1 MiB).

### P6 — Cloudflare Worker edge (source landed; deploy pending)

- `deploy/cloudflare`: the P0–P3 ingress as a `workers-rs`/`wasm-bindgen`
  Worker. Cloudflare terminates TLS and owns the wildcard origin; the Worker
  verifies the ticket (header/cookie/query), forwards it, and GETs the peer
  over `idfon/http3/1` via iroh's wasm relay transport. Same trust model as
  `crates/idfon-edge`; `idfon-core` gained a wasm build (its `transport` module
  is native-only, tokio `rt-multi-thread` is target-gated).
- Two `workerd`-specific workarounds, both in `deploy/cloudflare/README.md`:
  **trailing-dot relay hostnames** must be normalized (workerd rejects them in
  `fetch`/WebSocket, so iroh's default relay URLs and resolved peer addresses
  are rewritten), and `ring` must be archived with LLVM `ar` when building on
  macOS.
- Verified against a real native `iroh-h3-axum` peer under `wrangler dev`:
  ticket auth via header and cookie, forwarded ticket echoed by the peer,
  401 on missing/invalid tickets, `/healthz`, and the `/<ref>/<path>` route.
  The endpoint is built per request (stateless Workers drop isolate sockets;
  a cached endpoint hangs on a dead relay WebSocket). Not yet deployed to the
  `idfon.net` zone.

## Open decisions — recommendations

Proposed 2026-10-07, grounded in what P0–P5 landed plus the device/edge E2E.
Confirm to close.

1. **Edge runtime → Rust, with two deploy shapes (updated after P6).** The
   native `crates/idfon-edge` (Dockerfile, systemd unit, CI job, request metrics,
   real-`idfond` E2E in `scripts/edge-e2e.sh`) stays the self-host path and the
   direct/UDP-capable edge. For the public `idfon.net` zone, the P6
   `deploy/cloudflare` Worker is now viable: **no JS port is needed** — iroh 1.3
   and `iroh-h3-client` build for `wasm32-unknown-unknown` and run on `workerd`,
   reusing `idfon-core`'s ticket verification. It is relay-only and needs the
   trailing-dot normalization; pick it when running with no host/CDN ingress is
   wanted, and the native binary otherwise.
2. **URL form → `/<ref>/<path>` for 64-hex refs; wildcard only with a short
   ref.** Both are implemented (`Config.origin_domain`, `target()`), and the
   wildcard gives each peer a clean origin (path untouched, per-peer cookie
   scope). But a DNS label is capped at **63 octets** and an endpoint id (or
   `account_alias`) is **64 hex chars**, so `<ref>.<domain>` is unresolvable by
   any normal client — confirmed: `dig` rejects it (`label too long`); a
   `Host:`-header request (DNS bypass) works. Until a short host encoding lands
   (e.g. base32 of the 32-byte id = 52 chars, decoded by the edge), the
   **path form is the working public URL**; the wildcard cert/DNS stay for
   short handles and future encoding. A self-hosted edge on an IP still needs
   `--domain <host-or-ip>` so the `Host` check passes.
3. **Privacy posture → self-hostable and opt-in, no directory.** The edge is a
   relay, not an authority: it resolves a 64-hex ref to an iroh endpoint id (no
   directory), re-authorizes at the peer, and stores nothing. Joining is
   opt-in per owner (pair the edge + grant `resource.read`, or issue a
   path-scoped ticket). Ship one public edge for convenience *and* the
   Docker/systemd self-host path; do not make the public edge mandatory.
   Document that the edge sees request metadata/traffic.
4. **Auth timeline → P3 (owner-issued, path-scoped tickets) is v1.** P3 is
   landed and E2E-tested, authorizes the ticket *issuer* at the peer, and
   avoids option A's root-wide, edge-trusted grant. Option A (edge as a known
   peer) stays as the dev/simple mode. The edge's `--require-ticket` is a
   coarse gate; the peer re-checks issuer/grant/capability/path per request.

## Deferred / follow-ups

Knowingly deferred or only partially verified while landing P0–P5. Ordered by
value; check items off here as they land.

### Not exercised end-to-end

- [x] **Run the real `idfon-edge` as the phone's ingress.** `scripts/edge-e2e.sh`
  runs two real `idfond` daemons plus the `idfon-edge` binary (not the crate's
  fake H3 router) and asserts: ticket auth via header/cookie/`?ticket=`, the
  `<ref>.localhost` virtual-host form, health bypass, unknown-ref 404, option A
  (token auth + `resource.read` grant to the edge endpoint), P2's
  `idfon fetch --prefer edge` (`EdgeBackend`), and TLS termination. `--domain`
  wildcard DNS and per-IP rate limiting remain untested here.
- [x] **Ticket-over-H3 end-to-end.** The script issues an owner ticket with
  `idfon access ticket --path-scope /fs/public`, presents it to the edge, and the
  edge forwards it as `x-idfon-ticket`; the provider authorizes the issuer and
  enforces `path_scope` (a scoped ticket is 403 outside the prefix, an unscoped
  ticket reads it). `DaemonClient.fetchRemoteResource` still sends no ticket, so
  the iOS path is not yet covered.
- [x] **Background handoff (P4).** Triggered on device via the
  `-edgebghandoff` probe: a background `URLSession` download staged its bytes,
  survived a `sceneDidEnterBackground` → `sceneWillEnterForeground` cycle, and
  reconciled with the exact byte count. This found and fixed a **dead drain**
  (the reconcile hung off `AppDelegate.applicationWillEnterForeground`, which a
  scene-based app never calls) plus the error-body staging and cold-start
  session gaps. Residual: the download completed before the app was suspended,
  so "completes *during* suspension" and a system cold-start relaunch were not
  separately observed.
- [x] **`EdgeWebView` deep link (`idfon://<ref>/<path>`) and `idfon web open`.**
  `idfon web open <ref>/<path>` composes the edge URL (verified against a real
  daemon + edge). On device, `idfon://<ref>/fs/index.html` routed to
  `EdgeWebView` and rendered the edge-served HTML (edge `200`). Fixed on the way:
  the `idfon_ticket` cookie was always `Secure`, so WebKit dropped it over a
  plain-HTTP self-hosted edge; it is now `Secure` only for HTTPS, and a
  non-HTTPS edge also carries `?ticket=` (which the edge accepts). Residual: a
  non-endpoint-id ref (name/alias) is not resolved to an endpoint id before the
  edge URL is built, so a configured-edge deep link only works with the 64-hex
  ref.
- [x] **`action-audit.ndjson` receives the `ok:` line.** Confirmed on device:
  the app container holds `{"action":"idfon.peers",...,"outcome":"ok: Agency,
  GPT-6-Luna, ..."}` lines from the JSON-render button taps. Rotation to a
  single `*.1` at 1 MiB (`ActionAudit.rotateIfNeeded`) is host-checked.

### Deviations from the plan text (fix code or doc)

- [x] A resource ticket now authorizes **either** the peer itself (bearer,
  `issuer == self`) **or** an issuer this peer granted `resource.read` (a
  delegate, e.g. the edge). `ticket_authorizes` consults `has_grant` for a
  non-self issuer; `resource_ticket_authorizes_issuer_capability_and_path`
  covers grant and revoke.
- [x] **Path scoping stays on the ticket, not the grant (deliberate).**
  `CapabilityGrant` is a coarse per-capability grant; a signed `path_scope` on
  the ticket bounds one delegation and cannot be widened by the delegate. It is
  realized end-to-end by `scripts/edge-e2e.sh`.
- [x] **Edge trust model (documented).** The edge is not an authority: its
  `--require-ticket <cap>` is a coarse gate that the caller holds *some* valid
  ticket, and the peer re-checks issuer/grant/capability/path on every request.
  Run it with `--require-ticket resource.read` so one ticket satisfies both; the
  edge deliberately does not bind `subject == edge` (P3). See
  `crates/idfon-edge/README.md`.
- [x] **Expiry accepts epoch seconds and RFC 3339**
  (`idfon_core::expiry_passed`); an unparseable value counts as expired. The
  edge still requires a ticket to carry an expiry.
- [x] **Rate limit stays per `Caller.subject` (deliberate).** The subject is the
  authenticated ticket issuer; behind the recommended loopback + TLS-proxy
  deployment a socket IP is always the proxy, and `--token` is a single shared
  identity by definition. No per-IP bucket.

### External / ops (not in the repo)

- [x] **Co-located enterprise relay (#26).** Relays are the guaranteed path
  behind enterprise NAT (symmetric/CGNAT defeats hole-punching; often only TCP
  443 egress is allowed, which the relay's WebSocket transport traverses).
  `idfon-core` honors `IDFON_RELAY_URLS` / `IDFON_RELAY_TOKEN` (override N0) and
  `IDFON_RELAY_ONLY` (drop IP transports). `deploy/digitalocean/` ships
  `relay/config.toml` + `compose.relay.yaml`; `IDFON_DEPLOY_RELAY=1 pnpm
  deploy:do` provisions the relay, syncs the firewall ports (8443/tcp,
  7842/udp), and points the edge at it. Validated: a relay-only peer (its
  published address has no IP addrs) was fetched by the live edge through
  `relay.idfon.net:8443`. Every peer must share the relay; a peer left on N0
  will not rendezvous.

- [ ] **Cloudflare policy sign-off for the public edge.** Checked 2026-10-08:
  Self-Serve Subscription Agreement §2.2.1(j) forbids "provid[ing] a virtual
  private network or other similar proxy services", and an ingress relaying
  third-party peer traffic plausibly falls under it — this applies to the
  Services generally, so it gates the native edge behind Cloudflare's proxy
  too, not just the Worker. The old §2.8 non-HTML restriction is gone; the
  remaining video/large-file rule points at the paid Developer Platform, which
  Workers is. Before mapping `idfon.net`: get written confirmation from
  Cloudflare, or keep the edge DNS-only (grey-cloud) on a self-TLS host, or
  scope the edge to the owner's own resources. A paid Workers plan is also
  required (Free's 10 ms CPU is below an iroh handshake). Details:
  `deploy/cloudflare/README.md`.

- [x] `*.idfon.net` **DNS + certificate issuance + a host**. **Chosen path:
  a DigitalOcean droplet** running the native edge, with a Let's Encrypt
  wildcard cert via DO DNS (DNS-01). Everything is prepared in
  `deploy/digitalocean/` (runbook, `compose.yaml`, `acme-issue.sh`,
  `cloud-init.yaml`); `idfon-edge` gained an `IDFON_EDGE_KEY` env fallback so
  the identity need not be a host volume. **Deployed 2026-10-09** via
  `pnpm deploy:do` (droplet + reserved IP + firewall + DO DNS + wildcard cert);
  `https://idfon.net` is live. The **Cloudflare Worker**
  (`deploy/cloudflare/`) stays as a source-landed experiment, gated by the
  ToS §2.2.1(j) sign-off above and a paid plan.
- [x] Edge **request logging + metrics**: one structured `idfon.edge.access`
  event per served request (method/host/path/status/latency/caller/account) and
  Prometheus counters at `GET /metrics` (after requester auth).
  `EdgeMetrics`/`EdgeHandle.metrics` in `crates/idfon-edge`.
- [x] Edge **packaging**: `deploy/idfon-edge/{Dockerfile,idfon-edge.service}`
  and `.github/workflows/edge.yml` (gateway/edge crate tests, image build +
  `--help` smoke test, GHCR push on `edge-v*` tags).
- [ ] **Open decisions** — recommendations written (Rust edge; wildcard primary
  with path fallback; self-hostable/opt-in with no directory; P3 tickets for
  v1). Awaiting the owner's confirmation before the section closes.

### Parity / tests / docs

- [x] **macOS app parity.** The mac app now shares the Foundation-only web
  layer verbatim (`EdgeClient`, `BackgroundFetch`, `ActionAudit`,
  `JSONRenderModel`, `ArtifactGateway`, `RenderTools`) and ports the UI to
  AppKit: `JSONRenderView` (NSStackView/NSButton), `SandboxedArtifactWebView`
  gains the loopback/edge `source:` variant, and `ArtifactDetailViewController`
  renders shared-root artifacts through the gateway, json-render artifacts with
  the app-owned tool registry, and hands a suspended fetch to the edge
  (`fetchResource` direct→edge, reconcile on `applicationDidBecomeActive`).
  `-edgeurl <url> <ticket>` and `idfon://<ref>/<path>` are wired in the mac
  `AppDelegate` (deep link verified on the Mac: edge `200`, HTML rendered).
  Note: the shared files are now duplicated between `ios/Idfon` and
  `mac/Sources/Idfon` (the two build systems have no common target).
- [x] **iOS test target.** `ios/IdfonTests` is an app-hosted XCTest bundle
  (`@testable import Idfon`) covering the web layer: `IdfonURL` deep-link
  parsing, edge URL/cookie construction, `BackgroundFetch` bookkeeping,
  `ActionAudit` rotation, and json-render normalization. Run on a connected
  iPhone with `pnpm ios test`. It already caught a real bug (a
  `HTTPCookie(properties:)` Secure flag that a `false` value does not clear).
  Debug builds needed `SWIFT_COMPILATION_MODE = wholemodule` because the
  `@_cdecl` voice bridges duplicate their C thunks across incremental objects.
  UI/WebView/XCTest *UI* automation is still not covered.

### Small debt

- [x] **`Artifact.metadata` renderer hint is used.** Both apps decode the
  protocol `metadata` and honor `metadata.renderer`: `"json-render"` forces the
  native renderer, any other value forces the fallback, and an absent hint keeps
  parse-detection for legacy artifacts (`ArtifactDetailViewController.wantsJSONRender`).
- [x] **JSON-render catalog stays deliberately minimal** (7 components). This is
  a decision, not a gap: the agent supplies data only, and `state:set` /
  `sequence` / toast plus an MCP host are deferred until a producer needs them
  (YAGNI). Revisit with a state machine + MCP tools only then.
- [x] **`-edgeurl` / `-edgeticket` have a UI.** iOS: an **Edge** button on the
  Contacts screen; macOS: **Settings → Edge…**. Both edit the URL + ticket,
  persist through `EdgeClient.configure`, and offer Clear
  (`EdgeClient.clear()`); launch args still work and prefill the form.
- [x] **`EdgeClient` pending-task map and `edge-inbox` age cap.** Pending
  entries carry an `at` epoch and are pruned past a 24 h TTL on drain; a staged
  file older than the TTL is dropped instead of reconciled.
  `BackgroundFetch.pruned`/`isStale` are Foundation-only and covered by
  `ios/Checks/JSONRenderCheck`.
- [x] **Edge `load_tls` certificate reload/rotation.** `idfon-gateway` now
  serves through a `ReloadingCert` resolver that re-reads the cert/key when
  either file's mtime changes; a failed reload keeps the last good key so a
  half-written rotation never breaks TLS. Test:
  `reloading_cert_reloads_on_change_and_keeps_the_last_good_key`.

## Verification

- `cargo test -p idfon-edge` (edge e2e), `cargo test -p idfon-gateway`
  (H3 backend), `cargo check --workspace --all-targets`.
- `deploy/cloudflare`: `./build.sh` (wasm bundle) and `cargo check --target
  wasm32-unknown-unknown` from that directory; `wrangler dev` against a native
  H3 peer for the runtime path (see its README).
- Manual: start a provider (`idfon-mcp expose --root DIR`), pair the edge, and
  fetch `https://<peer>.idfon.net/fs/<path>` from a browser and from a `WKWebView`
  on device (background the app mid-fetch in P4).
