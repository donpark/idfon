# WebMCP bridgehead and the MCP app↔agent surface — plan

> **Status:** design, for implementation. Amended 2026-11-02 after an external
> design review (GPT-6.1 Sol): its blocker (the loopback gateway credential
> exposure) and majors are folded in below and tracked as the P-1/P0–P4
> subtasks of epic [#111](https://github.com/donpark/idfon/issues/111).
> Reasoning history: `idfon-web-analysis.md` (which chose app-owned JSON-render
> over WebMCP in 2026-10-09 — this plan adds the *tiered* escape hatch below
> that decision, it does not reverse it).

## The framing

Two different beasts, one useful overlap:

- **WebMCP works at the client side.** Its server is a page loaded and running
  in a browser/WebView — a bridgehead the web content already owns. It is a
  *page API*, not a network transport.
- **MCP is general.** It is how apps and agents exchange tools and context,
  whatever the transport. `idfon/mcp/1` already carries it peer-to-peer with no
  public endpoint (`mcp-transport.md`).

Idfon's play is therefore not "WebMCP over idfon" as one thing. It is:

**pages over the gateway for bytes, WebMCP as the in-page declaration shim,
MCP over `idfon/mcp/1` for tool exposure, grants for authority.**

MCP becomes the way apps and agents communicate; the loaded page is just one
more tool implementation behind the app's MCP server. One consequence to make
explicit: the app's MCP adapter exposes **native registry tools as well as
page-backed tools** — closing a page removes page implementations, not the
app's surface. No resources/prompts or larger framework is needed for that.

**The eve precedent governs:** bridge the framework, never fork it. `eve-idfon`
adapted eve without touching eve; the shim keeps the upstream WebMCP *shape*
(see §WebMCP compatibility subset — the shape is pinned and named, not assumed),
so divergence is confined to one shim file, not a protocol.

## Prerequisite (P-1, blocker): gateway credential and origin isolation

The 2026-11-02 review found that the loopback WebView used the identity-wide
gateway bearer in its URL, `TokenOnly::authorize` ignored account/path scope,
and the sandbox omitted the port from its origin check. **The code remediation
and P-1 acceptance gate are now complete.**

- `ArtifactGateway` now asks `gateway.start` for a one-hour signed credential
  bound to one account and the resource's containing directory. It loads from
  `http://localhost:PORT/<account>/<path>` and carries the credential in a
  path-scoped HttpOnly cookie, never the page URL.
- `TokenOnly::authorize` enforces the signed account/path scope. The unscoped
  bearer remains for trusted native requests over the 0600 daemon socket.
- The sandbox checks exact scheme, host, port, and resource-directory prefix for
  navigation and network loads. The gateway rejects a mismatched listener port.
- The public edge and Cloudflare worker accept HTTPS `__Host-` host-only cookies
  or the ticket header; URL credentials are rejected. Insecure HTTP edge pages
  are refused.

Rust tests pass for credential tampering/expiry and cross-peer reads. On a
physical iPhone 16 running iOS 27.2, all 14 `IdfonWebTests` pass. The source-load
WebView test verifies that same-directory assets load while cross-peer paths,
alternate ports, encoded traversal, and off-scope redirects are blocked; it also
checks that JavaScript cannot read the scoped cookie. The macOS
`ArtifactWebViewSourceCheck` runs the same production WebView against a local
fixture and passes the same negative cases. The full iOS suite still has two
unrelated `TimelineTests` failures.

**Wording correction:** the untrusted tier is not "zero bridge" — the sandboxed
web view already registers the `idfonSelect` selection channel. The invariant is
**no privileged action/tool bridge**, with the selection channel explicitly
accounted for.

## Layer decomposition (settled, amended)

| Layer | Carried by | Why |
| --- | --- | --- |
| Page delivery (HTML/JS) | `ArtifactGateway` — loopback gateway (iroh underneath) first, public edge fallback | WKWebView speaks HTTP; the gateway is the shim that makes iroh look like HTTP. P0–P4 of `idfon-edge.md` already do this; the P-1 credential and origin gate has passed on iOS and macOS. |
| In-page tool surface | WebMCP-shaped shim → `WKScriptMessageHandler` → native dispatcher (§Two directions) | No network transport involved. The page declares; the app enforces. |
| Tool exposure to agents | App-side MCP server over `idfon/mcp/1` (**stream profile**: newline-delimited JSON-RPC over a reliable bi-stream — not message-shaped) | The page is the tool *implementation*, the app is the MCP *server*, idfon is the *transport*. Tool-change uses MCP's `subscriptions/listen` + `toolsListChanged` subscription notifications — no new wire profile. |

## Two directions in the shim (do not conflate)

WebMCP registration means "store this page-owned `execute` callback so an agent
can invoke it." It does **not** mean "invoke an existing native action with this
name." The shim has two explicitly separate directions:

1. **Register (agent → page):** store the page callback; native code later
   invokes it and correlates the asynchronous result. Unregister on document
   replacement. Per page-document generation, so two pages may not collide.
2. **Act (page → native):** request an app-owned action through a separately
   authorized bridge (`RenderToolRegistry`'s dispatch path: allowlist, schema
   validation, `sensitive` confirm, `ActionAudit`).

Rules:

- **No native-name shadowing.** `RenderToolRegistry.register` currently
  overwrites by name (`tools[tool.name] = tool`); page registrations must be
  namespaced and must never replace an app-owned tool.
- **App policy — not page metadata — decides privilege.** A page marking its own
  tool `sensitive: false` cannot make page code harmless: arbitrary page code
  can act same-origin outside the registry. Granting `ui.serve` is granting the
  running of trusted-capability code; the registry constrains *native* effects,
  not everything the page does.
- **Confirmation shows what matters.** The current confirm dialog shows the tool
  description; it must show caller identity and the actual arguments (and
  destination for message-like actions). The registry also gains real JSON
  Schema validation and caller context — "reuse wholesale" applies to the
  dispatch/audit path only.

## Caller identity and adapter placement

The daemon MCP relay (`crates/idfon-daemon/src/mcp.rs`) verifies the
`mcp.transport` grant against `connection.remote_id()` and then spawns a fixed
command and pumps raw bytes — it does **not** tell the child who is calling. The
plan requires:

- The relay passes the **authenticated remote subject** (already computed in
  `inbound_allowed`'s peer lookup) to the user-side adapter over trusted local
  metadata. A caller-supplied conversation id or `_meta` identity is not proof.
- Per-shell routing contract (P3): the adapter must reach the **running GUI's**
  registry — a spawned child cannot see the page in that GUI. iOS needs an
  in-process route; mac the same shape.
- `ui.serve` (the page's publisher) and `ui.tools` (the calling agent) are
  distinct subjects and distinct grants — especially in group conversations.

The daemon rule stands: **the daemon relays bytes and authenticated transport
identity; the app adapter owns tool semantics.**

## Trust tiers (amended)

The `Data, not code` decision (`reply-blocks.md`) stands. Interactive pages are
a second, explicitly granted tier — never a widening of the first.

| Tier | Content | Surface |
| --- | --- | --- |
| Untrusted (today) | HTML/SVG artifacts | Sandboxed web view: in-memory scheme, non-persistent store, **no privileged action/tool bridge** (`idfonSelect` selection only), content rule list, off-scheme navigation cancelled. Unchanged forever. |
| Interactive (new) | Agent-served detail pages | Same sandbox + the fixed action bridge. Requires `ui.serve`. Tool calls from agents require `ui.tools`. Both gated on the P-1 credential fix. |

Grants follow `communication-model.md` exactly: `subject / capability /
direction / lifetime / scope`, revocable locally and immediately. Whether an
interactive page renders or runs at all is local UX policy, per contact.

## Lifecycle and scoping rules (amended)

- Bind registrations and calls to **(identity, conversation, page-document
  generation)** — not just a view and a tool name. Invalidate on document
  replacement (reload, same-origin navigation), close, page crash, expiry, and
  revoke. A second page registering the same name is a different generation,
  not an overwrite.
- **Recheck authorization after confirmation and immediately before privileged
  effects.** Revocation can land while a confirm dialog is open; today the
  registry awaits confirmation and then runs the captured tool unchecked.
- Pending calls are cancelled and stale results discarded on invalidation.
  Already-completed external effects cannot be undone — say so where the UI
  copy overpromises.
- Bounds: registration count, metadata/schema size, pending calls, execution
  timeouts.
- Page-registered tools exist only while the document they belong to is alive,
  bound to the conversation the page arrived in. `toolsListChanged` (via
  `subscriptions/listen`) informs subscribers on open/close — **notifications
  are not the authorization boundary.**
- Remote callers see page tools only if the contact holds `ui.tools` for that
  scope. Default off.

## Injection residual and disclosure policy (amended)

**Grants authorize exposure; they do not sanitize injection.** After an
authorized user opens a page, a poisoned page can still try to steer the agent
via anything page-controlled that reaches a model context: tool names and
descriptions, **schema descriptions and defaults, tool results, and errors**.
All of it is untrusted prompt text; provenance markers and untrusted-content
handling apply to all of it, not just names/descriptions.

- **Audience rules.** App data crossing into a page or a remote caller is
  governed by the underlying action's own permissions, independent of
  `ui.tools`. Native tools like `idfon.peers` are non-sensitive *for a local
  user*; handing their results to a remote caller changes the audience. A
  `ui.serve` grant must not silently grant contact-list access. Re-classify
  native tools by audience when P3 exposes them.
- **Native trusted chrome.** Consequential calls show publisher, caller, and
  arguments in app-owned UI, never in page UI.
- **Adversarial tests include an authorized-but-malicious page**, not only
  pages that lack grants.
- Voice/no-screen degradation keeps the artifact discipline: `metadata.spoken`
  and `metadata.alt`; a page never substitutes for a speakable summary.

## Where the pieces land

| Piece | Path |
| --- | --- |
| Block/protocol: the page link rides the block model (fail-open; old shells see `Unparsed`) | `crates/idfon-protocol/src/blocks.rs` |
| Gateway credential fix (P-1) | `crates/idfon-daemon` (gateway auth), `ArtifactGateway` + `SandboxedArtifactWebView` (both shells) |
| WebMCP-shaped shim + the two-direction bridge | new, both shells (`ios/Idfon`, `mac/Sources/Idfon`) |
| Enforcement: allowlist, schema validation, arg+caller-aware confirm, audit | `RenderToolRegistry` (extended) / `RenderTools` / `ActionAudit` (both shells) |
| MCP server + caller identity routing + `subscriptions/listen` | over `crates/idfon-mcp` (`idfon/mcp/1` stream profile) + the daemon relay's identity hand-off (`crates/idfon-daemon/src/mcp.rs`) |
| Grants | daemon grant model + app-side capability tickets |

The iOS/macOS UI duplication doubles the shell work; iOS is the proving ground,
mac follows the same shape the existing duplicated files do — **but iOS success
does not implicitly satisfy both-shell acceptance** (see the gate rule below).

## Phases (amended)

Each phase is independently shippable **except where marked dev-only**; gates
are device-verified against the acceptance matrix below.

- **P-1 — Gateway credential & origin isolation fix (blocker).** Scoped
  credentials, complete-origin/path sandbox checks, and negative tests are
  implemented and pass on physical iOS and the macOS host. This fixes an
  existing exposure regardless of this epic.
- **P0 — Detail page off a block.** A json-render item or artifact opens an
  agent-served page in the existing sandboxed web view over `ArtifactGateway`.
  No bridge beyond `idfonSelect`, no new trust surface. *Gate:* the UX is worth
  the rest (explicit human sign-off — a product judgment, not a test).
- **P1 — WebMCP shim → native dispatcher.** The two directions, namespaced
  registrations, schema validation, arg+caller-aware confirm, audit. **Dev-only
  for remotely supplied content until P2's grants land.** *Gate:* the
  acceptance matrix's permitted/denied/stale rows pass on the demo page.
- **P2 — Grants, tiers, lifecycle.** `ui.serve` / `ui.tools`, local UX policy,
  revoke with post-confirmation recheck, document-generation binding, the
  tier-split regression check. *Gate:* a contact without grants gets the
  untrusted tier; a revoked contact's in-flight confirm is denied and audited.
- **P3 — App-side MCP server over `idfon/mcp/1`.** Stream profile +
  `subscriptions/listen` + `toolsListChanged`; caller identity routing from the
  relay; conversation scoping; native registry tools exposed alongside page
  tools (audience-reclassified). **Dev-only for remote callers until P4.**
  *Gate:* a remote agent drives a page tool end to end on device — and the
  cross-conversation and revoke-during-call rows of the matrix pass.
- **P4 — Remote exposure safety.** The injection/disclosure policy above,
  default-off remote exposure, caller-attributed auditing, origin discipline,
  spoken/alt discipline, the `idfon-web-analysis.md` security checklist answered
  point by point for tier 2. *Gate:* the full acceptance matrix passes on both
  shells with the authorized-but-malicious demo page.

**Gate rule.** A small named acceptance matrix is the release criterion for
P1–P4: permitted action / denied action / foreign frame or origin /
cross-conversation access / revoke during confirmation / stale registration /
reload-and-close. Shared policy checks run once on shared code; shell-specific
checks run per shell.

## WebMCP compatibility subset

Upstream has moved already: the [WebMCP
explainer](https://github.com/webmachinelearning/webmcp) uses
`document.modelContext`, promise-based registration, abort-based
unregistration, discovery/execution APIs, and `toolchange`, plus frame and
permissions-policy behavior. MCP-B is a related *implementation* lineage with
real tab/extension transports — not a synonym for the browser API; "no
transport involved" applies to the in-page API only.

Therefore: **pin an upstream revision (by date) and name the implemented
compatibility subset in the shim's header.** Revisit on relevant API, security,
or lifecycle changes — not only "Chrome stable". Keep compatibility differences
localized to the shim, and do not promise rename-only migration or full WebMCP
compatibility. As of 2026-11-02 the shape to track is `document.modelContext`
(promise-based, abort to unregister); `navigator.modelContext` in earlier notes
is superseded.

## Open decisions (amended)

1. **Grant shape for `ui.serve`:** per-contact grant (lean — matches everything
   else in idfon) vs per-message user approval.
2. ~~Spec-watch trigger~~ — replaced by §WebMCP compatibility subset (pin a
   revision, name the subset, revisit triggers are enumerated there).
3. ~~`list_changed` session tweak~~ — replaced by an implementation task on the
   existing stream profile (`subscriptions/listen`, subscription-correlated
   `toolsListChanged`). Dynamic discovery needs **no new wire profile**.
4. **Catalog vs pages as the default answer:** JSON-render stays the default;
   a page is the escape hatch with an accessibility and voice cost. Guidance
   for agent authors should say so.
5. **Native-tool reclassification:** which of the existing `RenderTools`
   (`status`/`peers`, `message.send`) may cross to a remote caller at all, and
   under which grant.

## Issues

Epic [#111](https://github.com/donpark/idfon/issues/111) with subtasks
P-1 (blocker prerequisite) [#117](https://github.com/donpark/idfon/issues/117), [#112](https://github.com/donpark/idfon/issues/112) (P0),
[#113](https://github.com/donpark/idfon/issues/113) (P1),
[#114](https://github.com/donpark/idfon/issues/114) (P2),
[#115](https://github.com/donpark/idfon/issues/115) (P3),
[#116](https://github.com/donpark/idfon/issues/116) (P4).
