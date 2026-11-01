# Durable files: CDN-backed publication, independent of sessions and agents

> **Status:** as-built (2026-11-01) for the origin store and the publish path:
> `FilesRoutes` in `crates/idfon-edge` (`/files/*`, `/models/*`), the daemon's
> `files.publish` RPC and `idfon publish`, plus expiring rental pins. The
> BunnyCDN pull zone, `files.idfon.net`, signed URLs, per-tier quotas,
> per-renter ownership and takedown are not built; today the droplet serves the
> bytes directly and a CDN can be put in front of the same paths without code
> changes.

Agents and users need to serve files **independent of chat sessions and agent
life cycles**. The connected-only story is `iroh-blobs` + `BlobTicket`
(`docs/idfon-eve.md`, `docs/cli-data.md`): content-addressed and portable, but
**liveness-bound** — whoever holds the blob must be online to serve it. Agents
get redeployed, phones sleep, sessions end. The edge store is the always-on
tier.

## Tiers (the policy)

| Tier | Where bytes are served | Durability |
| --- | --- | --- |
| **Free** | from the publisher while connected — `BlobTicket` fetch (`idfon put` / `idfon get`), or the edge proxy `<ref>.idfon.net/<path>` | none beyond the publisher's own storage. No edge copy. |
| **Free pin (today)** | from the edge's durable store (and the CDN) at a content-addressed URL | **24 hours**; a user publish defaults to and is capped at 24h until a paid tier exists |
| **Operational** | the same store, published with the operations token | **never expires** (`idfon publish --permanent`, or rsync the directory) |
| **Paid** | the same store, longer terms | not built |

The free tier is harsh but the economics are what they are: an always-on copy
of everyone's files is the thing being sold. Until that is sold, every
user-facing pin is a 24-hour trial; files the service itself needs (model
packs, manifests) are pinned permanently with the operations token.

## Content-addressed URLs

Blobs are already hash-addressed. Publish at
`https://<edge>/files/sha256/<sha256>` (or through the CDN at
`https://files.idfon.net/sha256/<sha256>`) and the hard problems evaporate:

- **immutable** — cache forever at the edge, zero invalidation
- **integrity** — the hash is the URL, and the edge verifies the body against it
- **multi-tenant safe** — agents and users cannot overwrite each other's
  files; dedupe is free
- mutable names, where wanted, are small manifest objects pointing at hashes —
  the `bundle.json` pattern

An object is stored once, at `<files-dir>/sha256/<hash>`, whatever path prefix
the request used. That is what lets a `bundle.json` list relative
`sha256/<hash>` paths next to itself.

## Edge routes (`FilesRoutes`)

Mounted only with `--files-dir`; served before requester auth, like `/_push/*`.

| Request | Meaning |
| --- | --- |
| `GET`/`HEAD /files/<name...>` | mutable named file (`cache-control: no-store`) |
| `GET`/`HEAD /files/<prefix...>/sha256/<hash>` | content object (`cache-control: … immutable`) |
| `GET`/`HEAD /models/<name...>` | alias for model packs (`/models/phonon-31m/...`) |
| `PUT` on either form | publish (requires `--files-token`) |

- Uploads stream: the request body is never collected or capped at the
  gateway's `MAX_RESOURCE_BYTES`; files of any size go through.
- Content writes are verified against the URL hash (mismatch = `400`) and
  idempotent: a `HEAD` hit or a second `PUT` reports `existed: true`.
- `--files-quota-mb N` (default 0 = unlimited) caps the store. Over quota
  stops new pins with `507` and never deletes existing ones.
- `--files-max-expiry-days N` (default 0 = no cap) clamps a requested term;
  `--files-grace-days N` (default 30) keeps expired bytes before delete.
- `--files-user-expiry-hours N` (default 24, `0` = no default) is the user
  pin term; `--files-ops-token` enables permanent operational pins.
- `--files-max-upload-mb N` (default 100, `0` = unlimited) caps a single
  **user** upload; operations uploads are trusted and bound by the store quota.
  A user upload over the cap is refused with `413` (checked from
  `Content-Length` and again while streaming, so a chunked body cannot bypass
  it).
- Names are `[A-Za-z0-9._-]` segments; `..`, empty segments and traversal are
  refused. Uploading a name overwrites it in place.
- No `Range` support yet: a resumed download refetches the whole object (the
  apps verify size + SHA-256 per file anyway).

## Publish path

```sh
# Free tier: connected-only ticket (the publisher must stay online).
idfon put --file report.pdf            # prints a BlobTicket

# Durable tier: an always-on copy at a hash URL.
idfon publish report.pdf               # user pin: 24h
idfon publish report.pdf --expires-in 1h
idfon publish bundle.json --name phonon-31m/bundle.json --permanent   # ops pin
```

`idfon publish` (daemon `files.publish { path, name?, url?, token?, expires_in?, permanent? }`):

1. computes SHA-256 client-side (the daemon reads the file, not the socket),
2. `HEAD`s the content URL and skips the upload if the edge already has it,
3. streams the file to the edge, which verifies the hash and stores it,
4. returns `{ url, sha256, size, existed, expires_in, permanent }`; the URL
   sits in the name's directory so relative bundle paths resolve.

Configuration on the daemon: `IDFON_EDGE_URL` (base, e.g. `https://idfon.net`),
`IDFON_FILES_TOKEN` (user bearer; falls back to `IDFON_EDGE_TOKEN`) and
`IDFON_FILES_OPS_TOKEN` (operations bearer, used by `--permanent`). `--url` /
`--token` override per call.

## Pin terms: 24h user pins, permanent operational files

Two upload tokens, two policies:

- **`--files-token` (user)** — every pin lasts **24 hours**: no term defaults
  to 24h, an explicit term is capped at 24h (a shorter one is honored). Set
  `--files-user-expiry-hours N` to change the default/cap; `0` restores the
  old unlimited behavior for a self-host. `--expires-in` is
  `x-idfon-expires-in` (seconds) or `x-idfon-expires-at` (unix).
- **`--files-ops-token` (operations)** — publishes are **permanent** unless a
  term is requested. `x-idfon-pin: permanent` (CLI: `idfon publish
  --permanent`) forces it; a user-token request for it is refused with `403`.
  Ops can still set a temporary term with `--expires-in`.

- Expiry is keyed by **object** (`sha256/<hash>`) or **name**
  (`name/<segments>`), so every URL form of an object shares one term, and the
  latest grant wins. A later 24h user pin does not shorten a permanent object
  (it has no pin).
- At expiry the route answers `410 Gone` with `cache-control: no-store`. A
  content URL with time left is served `public, max-age=<remaining>`, so a CDN
  in front cannot outlive the term (no purge dependency). Names are
  `no-store`, so a CDN never serves a stale `bundle.json`; permanent objects
  are `immutable`.
- Bytes are deleted only after the grace period (`--files-grace-days`, default
  30), so a lapse is reversible inside the window; the sweep runs hourly, at
  startup, and before each upload. Expired-but-not-yet-deleted pins still
  count against quota.
- `--files-max-expiry-days` still caps any requested term (ops included).
- Billing is not on the edge: a paid tier would need per-owner upload
  credentials and per-renter pin records — see "Not built yet".
- **Scope: published resources only.** The size cap (and the 24h term) cover
  the durable store. Live audio/video (`idfon send --stream`), 1:1 calls, and
  connected-only `BlobTicket` transfers are runtime streams from the
  publisher's endpoint; they are gated by grants/tickets but not by this cap.
  A streaming/media policy would be a separate control.

## Origin and deployment

- The droplet runs the native `idfon-edge`; point it at a directory:
  `--files-dir /srv/idfon-edge/files --files-token <secret>`. Without a token
  the store is read-only, so an operator can rsync content instead of using
  the HTTP publish path.
- **BunnyCDN** (pull zone) is the default: `deploy/bunny/setup.sh`
  (`docs`-free, idempotent) creates the zone, the `files.idfon.net` custom
  hostname, the free certificate, and — when `DIGITALOCEAN_API_KEY` is set —
  the CNAME. The CDN pulls `https://idfon.net/sha256/<hash>` (the edge matches
  the trailing `/sha256/<hash>` at any prefix) and serves
  `https://files.idfon.net/sha256/<hash>`. See `deploy/bunny/README.md`; two
  settings matter:
  - **Smart Cache must stay OFF** — it restricts caching to a known extension
    list, and content URLs are extensionless.
  - cache overrides stay `-1` (bunny's "no override", not `0` — `0` means
    "cache for zero seconds" and bypasses caching): the edge sends
    `max-age=<remaining>`, `immutable`, or `no-store`, so the CDN follows the
    rental term and never caches a mutable name.
  The app's `defaultPackURL` must point at `https://files.idfon.net/...` to use
  the CDN; pointing it at `idfon.net` bypasses it (the `/models` alias works on
  either host).
- **Cloudflare R2** stays the alternative only if DNS ever moves to
  Cloudflare; its zero egress fee is the draw.
- Private files would use provider-standard signed URLs with a TTL (not
  built). Today every published object is public by URL possession.

## First customer: the Phonon model pack

`scripts/build-phonon-pack.sh` already emits `bundle.json` (a content-derived
`built` stamp plus every file's size and SHA-256). The pack shape maps directly:

- `bundle.json` → a named file (`--name phonon-31m/bundle.json`), stable URL,
  `no-store`;
- every listed file → `sha256/<hash>` (write the hashed copies in the build
  script and list those relative paths);
- the app keeps `PhononTtsEngine.defaultPackURL` at
  `https://idfon.net/models/phonon-31m/` — `/models` is an alias of the same
  store, so the baked-in URL works without an app change.

Remaining for #101: emit hashed paths in the pack build, rsync
`dist/speech-packs/` to the droplet's files dir (or publish them), and run the
fresh-install device E2E.

## Not built yet

- Bunny pull zone + `files.idfon.net` CNAME (ops).
- Signed URLs for private files; public-by-default is today's choice.
- Per-owner upload credentials and per-renter pin records: with one shared
  upload token the edge cannot tell renters apart, so expiry is one grant per
  object/name (the control plane owns billing).
- Tier quota numbers/pricing, automated renewal, abuse/takedown path.
- An agent-facing tool (`idfon-mcp` / Eve bridge) beside `idfon publish`;
  today agents get `blob.put`/`blob.fetch` tickets only.
- Upload retries/resume and `Range` downloads.
