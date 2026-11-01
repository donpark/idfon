# Durable files: CDN-backed publication, independent of sessions and agents

> **Status:** design (2026-11-01). Tier policy decided: paid tiers buy CDN
> durability; the free tier stays connected-only. First customer: the Phonon
> model pack (see `scripts/build-phonon-pack.sh`, `PhononTtsEngine.defaultPackURL`).

Agents and users need to serve files **independent of chat sessions and agent
life cycles**. Today's durable-files story is `iroh-blobs` + `BlobTicket`
(`docs/idfon-eve.md`, `docs/cli-data.md`): content-addressed and portable, but
**liveness-bound** — whoever holds the blob must be online to serve it. Agents
get redeployed, phones sleep, sessions end. This adds the always-on tier.

## Tiers (the policy)

| Tier | Where bytes are served | Durability |
| --- | --- | --- |
| **Free** | from the publisher while connected — `BlobTicket` fetch, or the edge proxy `<ref>.idfon.net/<path>` | none beyond the publisher's own storage. No CDN copy. |
| **Paid** | from the CDN edge at a content-addressed URL | pinned independent of publisher liveness; quota per tier (storage + egress) |

The free tier is harsh but the economics are what they are: an always-on copy
of everyone's files is the thing being sold. Paid tiers set the quota numbers
(open question below); exceeding quota stops new pins, never deletes.

## Content-addressed URLs make the CDN trivial

Blobs are already hash-addressed. Publish at
`https://files.idfon.net/sha256/<hash>` and the hard problems evaporate:

- **immutable** — cache forever at the edge, zero invalidation
- **integrity** — the hash is the URL (the same contract `bundle.json` uses:
  every listed file carries its SHA-256)
- **multi-tenant safe** — agents and users cannot overwrite each other's
  files; dedupe is free
- mutable names, where wanted, are small manifest objects pointing at hashes —
  again the `bundle.json` pattern

## Provider and origin

- **BunnyCDN** (pull zone) is the default: a custom hostname
  `files.idfon.net` works as a CNAME with DNS staying at DigitalOcean. No zone
  migration — the edge stays the native `idfon-edge` on the droplet (the
  Cloudflare Worker prototype is abandoned: idfon needs UDP, which workerd
  cannot do for the proxy path).
- **Cloudflare R2** stays the alternative only if DNS ever moves to
  Cloudflare (R2 custom domains require the zone there); its zero egress fee
  is the draw.
- **Origin = the droplet** (already 24/7): the CDN pulls from it. Bunny
  Storage is the step up when the droplet should stop holding the bytes.
- Private files (if wanted) use provider-standard signed URLs with a TTL —
  content addressing stays the identity, the signature is the grant.

## Publish path

- `idfon publish <file>` (CLI) and a matching agent tool: upload by hash,
  return the URL. The free tier returns a `BlobTicket` instead — same
  content-addressed contract, no always-on copy.
- Upload is a content-addressed write (`sha256` computed client-side, server
  accepts or reports "already have it").

## First customer: the Phonon model pack

The pack is exactly this shape already: a stable `bundle.json` (small,
`no-cache`) listing files by SHA-256. Moving its files to hashed paths under
`files.idfon.net` is a ~5-line change to `scripts/build-phonon-pack.sh`, and
`PhononTtsEngine.defaultPackURL` moves to the CDN hostname when it exists.
Until then the droplet serves `/models` directly (`ModelRoutes` in
`crates/idfon-edge`), which doubles as the CDN origin path later — zero app
changes to slot the CDN in front.

## Open questions

- Tier quota numbers (storage GB / egress) and what each tier costs.
- Retention on downgrade/lapse: grace period, then unpublish (never silent
  deletion of pinned bytes without notice).
- Abuse: what a published file may contain, takedown path per tier.
- Private-file defaults for agent-emitted artifacts (today's artifacts ride
  `BlobTicket`; do paid pins default public or private?).
