# idfon:// addressing and the gateway

> **Status:** addressing landed; the gateway library and one folder provider are
> scaffolded (`crates/idfon-gateway`, `idfon-mcp fs`). The gateway's default
> backend is a placeholder until the resource protocol lands. Written
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

`IrohBackend` is the default backend and currently a placeholder (path in, bytes
out over `idfon/gateway/1`). It should become an MCP client over the existing
`idfon/mcp/1` transport, so one protocol serves the gateway, Eve, and every MCP
host — see "Next".

## The folder provider

`idfon-mcp fs --root <dir> --account <id>` is a read-only MCP 2026-07-28
resource server over one directory:

- `resources/list` (bounded recursion), `resources/templates/list`
  (`idfon://<account>/fs/{path}`), `resources/read` (text or base64 blob).
- Traversal- and symlink-escape safe; `_meta` protocol version enforced.
- Run it under `idfon-mcp serve --command` to expose the folder over
  `idfon/mcp/1` — which is exactly what the gateway's MCP-client backend will
  read. It also works directly for a local MCP host.

This is the "apps and agents decide what to expose" shape: the provider is the
exposure, the gateway is the local HTTP door, and grants remain the boundary.

## Next

1. Replace the gateway's placeholder ALPN with an MCP-client backend over
   `idfon/mcp/1` (reuses `resources/read`; no new protocol).
2. Embed the gateway once (daemon, user side) and run one end-to-end test:
   loopback request → peer → resource bytes.
3. Multiple roots / provider kinds when a second provider actually exists.
4. For artifacts specifically, the detail screen fetches bytes locally today;
   routing it through `idfon://<account>/artifacts/<id>` is the remote-view
   follow-on (`docs/idfon-artifacts.md`).
