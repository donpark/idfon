# MCP control surface: approval model

**Status:** slice 1 implemented (2026-11-10) — the tools below are live
(`diag.tail` / `wake.trace` in `idfon-mcp`, `/_push/health` on the edge,
daemon-side view materialization from `IDFON-DIAG/1` envelopes); the approval
model below is design. Companion to `docs/mcp-transport.md` (the
transport binding), `docs/diag.md` (`IDFON-DIAG/1`), and
`docs/callkit-brittleness.md` (why this exists: every incident becomes a
*question* instead of log archaeology).

External agents diagnose and debug idfon — apps, daemons, the edge — through
MCP tools over iroh. The surface is **control-grade**, so its access model is
the product, not a footnote.

## Three tiers

1. **Own devices and the monitor** — standing grants via self-issued
   capability tickets. The `IDFON-DIAG/1` channel already works this way.
   No UX friction, no new surface.
2. **Approved external parties** (an agent, customer support) — approval at
   request time, over the already-paired iroh connection. Approval issues a
   **short-lived, subject-bound, verb-scoped ticket** (`capability.ticket`
   machinery); revocable through the existing `access`/grants family.
3. **Public / unpaired contacts** — no surface at all by default. A support
   scenario that needs one grants a **one-shot expiring ticket** through the
   contact-exchange flow (QR/link). Never a standing right; never a
   control-class verb.

## The approval block

A request arrives → an approval card shows, user decides:

> **who** · verified display name + identity prefix (approve-by-*identity*,
> never by claim — the pairing already authenticated the channel)
> **what** · tool name + human summary + **redacted args**
> **scope** · verb class (`diagnostics.read` / `call.control` / …)
> **duration** · once / 10 min / this session
> **actions** · Deny · Allow once · Allow 10 min · Always for this tool

Rules that keep it honest:

- **Deny by default.** A request not approved within N minutes dies (bounded
  waits); approvals serialize through one queue (no approval races).
- **Verb classes are separate tickets.** Reads never share a grant with
  `call.control`-class actions (dial/hangup are never permanently grantable).
- **Everything is audited** — `mcp.request` / `mcp.approved` / `mcp.denied`
  events on the `Diag` channel, with scope and duration. The audit rides the
  channel it audits.
- **Opaque args are denied.** If the summary cannot render the arguments
  human-readable, the card offers only Deny — an unreadable tool call is a
  prompt-injection surface, not a feature.
- **First-contact TOFU.** The first approval from a given identity shows a
  stronger card (key fingerprint, "remembered for this tool only").
- **"Always for this tool" is rare and loud** — and unavailable for control
  verbs entirely.

## Lock-screen approval (the customer-service case)

The user is on a call with support, phone locked, and an agent needs
diagnostics. Settings expeditions mid-conversation are the failure mode this
design removes: the approval request rides the **push wake chain** as an
actionable notification ("Agent X requests `diag.tail` since 01:40 —
Allow once / Deny"), one tap on the lock screen. This reuses the hardened
`/_push/*` plumbing; the approval's own verb-scope and TTL are decided by the
same rules above.

## Tool surface (initial slice)

Read-only first, behind `diagnostics.read`:

- `diag.tail(device?, since?)` — the `IDFON-DIAG/1` event stream from the
  monitor's JSONLs.
- `wake.trace(call)` — one call attempt reconstructed from those events
  (registration → ring → push → report → answer → media), the queryable
  replacement for log archaeology.
- `edge.health` — the edge's push registry: registered tokens per ref, last
  `rung` counts, APNs errors, offer store (the C18/C19 questions).

Later, behind `call.control` and only tier 1–2: `call.dial`, `call.hangup`,
`push.re-register`, `mode.set` — turning `scripts/ring-e2e.sh` into an
agent-run scenario against a real device.

## Invariants

- The control surface is reachable **only over iroh** (the MCP transport
  binding); no public HTTP endpoint, ever.
- Every grant is a ticket with a subject, a scope, and an expiry.
- A tool's read path cannot mutate; control verbs are separate tools, not
  flags.
- The suspended-app window is out of reach by design (frozen process); the
  monitor's filed history answers for it after the wake.
