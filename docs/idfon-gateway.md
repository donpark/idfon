# idfon:// addressing and the gateway

> **Status:** all landed and tested. `idfon://` addressing; the loopback gateway
> library (`crates/idfon-gateway`) fetching over HTTP/3-over-iroh
> (`crates/idfon-h3`); the daemon-embedded `gateway.start` / `provider.start`
> RPCs; and the folder provider (`idfon-mcp fs` / `idfon-mcp expose`). Written
> 2026-09-29.

Two pieces of the `docs/idfon-http-routing.md` idea are real now: a single
`idfon://` namespace, and a reusable loopback HTTP surface for serving account
resources to a consumer (a WebView, an MCP host, a local tool).

## Addressing (`idfon://`)

Grammar (RFC 3986 hierarchical form), parsed by `IdfonURL` in both Apple apps:

```
idfon://<ref>[/path...]     resource
idfon://dial/<ref>          verb   (also videodial, answer)
```

- `ref` resolves against the local peer list: peer id, name, alias, endpoint
  id, and (iOS) device endpoint ids — the daemon's own `ref` rule.
- An endpoint-id host is normalized to lowercase hex. Reserved verbs
  (`dial`, `videodial`, `answer`) are matched case-insensitively and never name a
  peer; resource refs keep their case.
- **Derived account handle:** `idfon_core::account_alias(account_id)` is
  `blake3(account_id)` hex, stored as a reserved peer alias
  (`ensure_account_alias` on `peer.add`/`peer.update`, backfilled on load). Any
  contact already carries `account_id`, so `idfon://<handle>` resolves without a
  new ticket field or protocol bump. The handle is 64 hex — the same shape as a
  peer id — which is fine because refs resolve by matching a field set, not by
  dispatching on shape.

A peer can also carry a virtual account id (`--account-id`), which can differ
from its endpoint id; `idfon://<account>` addresses the account, endpoint ids
are device-scoped aliases that resolve to it.

Uncommitted by design: the `idfon://` scheme is registered on iOS
(`CFBundleURLTypes`); macOS registers it too and handles it in
`ApplicationDelegate`. Adopting it as a machine-facing HTTP scheme is the
gateway's job below.

## The gateway library

`crates/idfon-gateway` is a **library**, not a process: embedders supply
identity and policy, agents can ignore it and keep their own IPC.

- `Backend { async fetch(account, path) -> Resource }` — where resources come
  from.
- `Authorizer { authorize(account, path) -> bool }` — per-request policy, so the
  gateway never invents an allow rule.
- `serve(Config, backend, authorizer) -> GatewayHandle { local_addr, shutdown }`.

Addressing on the wire:

```
idfon://<account>/<path>  <->  http://<account>.localhost:<port>/<path>
                               http://127.0.0.1:<port>/<account>/<path>
```

The virtual-host form is preferred: the path passes through untouched, so a
provider's own routes survive.

Safety defaults: loopback bind; a bearer token is **required** for any
non-loopback bind and compared in constant time; `Host` and `Origin` are
validated (DNS rebinding); `..` is rejected; GET only.

`IrohBackend` is the default backend: it resolves the account ref to a dialable
peer, then issues a `GET <path>` over HTTP/3 over iroh (`idfon/http3/1`, see
`crates/idfon-h3`) and returns the response body and content type. The peer hosts
an axum router with `idfon_h3::serve_router`. Ref resolution needs the peer
store, which the gateway does not own, so the embedder supplies an
`AccountResolver` (`idfon://` account handle, id, alias, name → `EndpointAddr`);
an unresolved ref is a 404. MCP resources remain available over `idfon/mcp/1`
for MCP hosts, independent of the gateway.

The daemon embeds one loopback gateway per identity on demand. `gateway.start`
(over the 0600 socket) binds it and returns `{addr, url, token}`;
`gateway.stop` drops it. The CLI exposes these as `idfon gateway start` /
`idfon gateway stop`, and `idfon fetch idfon://<account>/fs/<path>` fetches a
resource through the running gateway to stdout or `--out FILE`. The
`AccountResolver` reads the same peer store as message send (id, name, alias,
endpoint id → `dial_targets()`), and the bearer token is the boundary — loopback
alone is not.

The daemon can also serve a **live, user-visible directory** in place.
`provider.start {root}` exposes `GET /fs/<path>` over H3, gated by a
**`resource.read`** grant for the caller: the endpoint id from the QUIC
handshake maps to a peer via `knows_endpoint`, and no peer or no active grant is
a 403. Grants are revoked live — the check runs per request. `idfon provider
start --root DIR` / `idfon provider stop` control it; grant with `idfon access
allow --subject <peer> --capability resource.read`.

The daemon keeps **no copy and no registry** of what it serves: the path is
resolved on request, so a file the owner deletes or renames is gone (or moved)
on the next request. `idfon://<account>/fs/<path>` addresses the directory
(`session_1/chart/result.html`), and paths are validated with `idfon_core::path`
(no `..`, no absolute; symlink escape rejected after canonicalization). Session
assets (a conversation's log and artifacts) are **not** in this namespace — they
live in the app-side session cache, and only explicit saves/shares reach the
shared root.

Both apps expose a dedicated, user-visible `Documents/Shared` directory:
`startSharedProvider` creates it and calls `provider.start` at launch, and the
iOS `Info.plist` enables Files/picker visibility. So "share a file" is just
"drop it in `Idfon/Shared`" (Files on iOS, Finder on macOS); paired channels are
granted `resource.read` alongside the message/live capabilities. The dedicated
directory is the boundary — an unscoped `resource.read` reads only what the user
chose to put there.

## The folder provider

`idfon-mcp fs --root <dir> --account <id>` is a read-only MCP 2026-07-28
resource server over one directory:

- `resources/list` (bounded recursion), `resources/templates/list`
  (`idfon://<account>/fs/{path}`), `resources/read` (text or base64 blob).
- Traversal- and symlink-escape safe; `_meta` protocol version enforced.
- Run it under `idfon-mcp serve --command` to expose the folder over
  `idfon/mcp/1`, for a local MCP host.

`idfon-mcp expose --root <dir> --account <id>` is the same folder over HTTP/3
(`idfon/http3/1`): `GET /fs/<path>` returns the bytes and mime type, reusing the
same traversal and size checks. It prints an endpoint ticket, and the gateway
reaches it as `idfon://<account>/fs/<path>`. The router builder
(`idfon_mcp::fs::router`) is a library function, so an embedder can serve,
compose, or authorize it without running the binary.

This is the "apps and agents decide what to expose" shape: the provider is the
exposure, the gateway is the local HTTP door, and grants remain the boundary.
The standalone folder provider is an *explicit* exposure (running it with
`--root` is the consent); the daemon's media-resource provider is a *granted*
exposure (per-caller `resource.read`).

## Next

1. App-side session cache: *landed.* `SessionStore` keeps the message log
   (per identity/conversation, ephemeral cache by default, opt-in
   `persistLogs` moves it to Application Support) plus cached ticket-addressed
   artifact bytes. The mac Sessions menu toggles `persistLogs`; both apps'
   artifact detail has **Save to Shared**, which writes the bytes into the
   served `Documents/Shared` directory so a granted peer can fetch them.
2. `media.resource.put` collapsed: *landed.* Chunks stage in `data_dir/staging`
   (swept on boot, pruned by age) and the ticket is the artifact; the durable
   `resources/` directory and the dead `get`/`register`/`delete`/`gc`/`resources`
   RPCs are gone.
3. Per-path/​session scoping for `resource.read` (the grant already carries a
   `conversation`) only if a served root ever holds more than one tenant; the
   dedicated `Shared` directory keeps the boundary at the file today.
4. macOS TCC: the separate `idfond` subprocess reading `~/Documents` may need
   consent; fall back to an app-group / in-process provider if it is blocked.
5. Two H3 folder providers by design: `idfon-mcp expose` is a standalone
   process (explicit `--root`, no grants) for an agent/tool that has no daemon;
   the daemon provider is identity-integrated (`provider.start`, per-caller
   `resource.read`). Keep both; consolidate only if a third shape appears.
6. Multiple roots / provider kinds when a second provider actually exists.
