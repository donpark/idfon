# Durable files: CDN-backed publication, independent of sessions and agents

> **Status:** as-built (2026-11-01) for the origin store and the publish path:
> `FilesRoutes` in `crates/idfon-edge` (`/files/*`, `/models/*`), the daemon's
> `files.publish` RPC and `idfon publish`, plus expiring rental pins, the
> Phonon pack delivery (content-addressed objects + app downloader), the
> BunnyCDN pull zone (`files.idfon.net`), an ops-only takedown with a sticky
> blocklist, and per-role write rate limits. Paid tiers, private/signed URLs
> and per-owner credentials are intentionally not planned; the free and
> operational policies are the product.

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
| **Free pin** | from the edge's durable store (and the CDN) at a content-addressed URL | **24 hours**; a user publish defaults to and is capped at 24h |
| **Operational** | the same store, published with the operations token | **never expires, no per-file limit** (`idfon publish --permanent`, or rsync the directory); the disk is the only bound |

The free tier is harsh but the economics are what they are: an always-on copy
of everyone's files is the thing being sold. There is no paid tier, so every
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
| `PUT` on either form | publish (user or operations token) |
| `DELETE` on either form | operational takedown: removes bytes + pin (operations token only) |

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
- `--files-writes-per-minute N` (default 60, `0` = unlimited) caps PUT/DELETE
  per role. Local routes bypass the gateway's rate limiter, so the store owns
  this one.
- `--files-max-upload-mb N` (default 2, `0` = unlimited) caps a single
  **user** upload. Operations uploads have no per-file limit and are exempt
  from the store quota (the disk is the bound); the quota is a user-abuse
  control.
  Two megabytes is roughly four minutes of 32–48 kbps Opus speech (32 kbps
  ≈ 1.4 MB, 48 kbps ≈ 1.9 MB; 64 kbps exceeds it). A user upload over the cap is refused with `413` (checked from
  `Content-Length` and again while streaming, so a chunked body cannot bypass
  it).
- Names are `[A-Za-z0-9._-]` segments; `..`, empty segments and traversal are
  refused. Uploading a name overwrites it in place.
- `DELETE` is the takedown path: it needs the **operations token**, removes the
  bytes and any pin, is idempotent (`204`), and records the key in the
  persisted **blocklist** (`blocked` in `pins.json`) so the same hash/name
  cannot be re-published. Reads of a blocked key answer `410`. Reports go to
  the operator; there is no self-service report UI.
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

### Agent tool

The Eve ingress exposes `publish_file` (`integrations/eve-idfon`):

- `path` or `content`, optional `name`, `durable` (default true),
  `expires_in`, `permanent`.
- The local bridge (`POST /files/publish`) forwards the bytes to the edge with
  `IDFON_FILES_TOKEN`, or `IDFON_FILES_OPS_TOKEN` for `permanent`; the edge
  applies the same 2 MB / 24 h and permanent rules. Errors (413, 403, quota,
  hash mismatch) come back verbatim.
- `durable: false` returns a connected-only `BlobTicket` through the existing
  blob store. The bridge accepts request bodies up to 8 MB (base64), which fits
  a 2 MB user file with headroom; larger operational files should use the CLI
  or rsync.
- Quota is the deployment's (the bridge's edge token), not the calling
  contact's; per-owner credentials are intentionally not built.

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

## First customer: the Phonon model pack

Delivered end to end (2026-11-01). The pack is still the same bundle — a
content-derived `built` stamp plus every file's size and SHA-256 — but the
served bytes are content-addressed while the installed layout is unchanged:

- `scripts/build-phonon-pack.sh` writes the pack layout and `bundle.json`,
  then `scripts/link-phonon-sha256.py` verifies every listed size/hash and
  hardlinks it at `<pack>/sha256/<sha256>` (no doubled disk).
- `bundle.json` is a **name** (`/models/phonon-31m/bundle.json`, `no-store`).
  Each `path` is the install location; each `sha256` is the URL
  (`/models/phonon-31m/sha256/<hash>`, immutable). Two flow weights are
  byte-identical, so 40 files dedupe to 39 objects.
- The apps' `PhononPack` downloader fetches the manifest, then each file from
  `sha256/<sha256>`, verifies size + SHA-256, and installs it at the manifest
  `path` (Core ML directories and voice filenames survive). It keeps an
  already-installed pack usable when the network is down. This local
  downloader exists because upstream `xn-ptts`'s `PhononModels.download` uses
  `path` for both URL and destination, and the package is pull-only.
- `PhononTtsEngine.defaultPackURL` is
  `https://files.idfon.net/models/phonon-31m/` in both apps; env/launch-arg
  overrides still work for local pack servers (which now need the `sha256/`
  tree too).

Deploy:

```sh
rsync -a --chmod=D755,F644 dist/speech-packs/phonon-31m/sha256/ \
  <droplet>:/srv/idfon-edge/files/sha256/
rsync -a --chmod=D755,F644 dist/speech-packs/phonon-31m/bundle.json \
  <droplet>:/srv/idfon-edge/files/phonon-31m/bundle.json
ssh <droplet> 'chown -R 10001:10001 /srv/idfon-edge/files'
```

Permissions matter: the edge runs as uid 10001. Pack voice files are created
mode 600 locally, so root-owned 600 objects return 404; and a root-owned
`sha256/` directory makes uploads fail with `500 Permission denied`. The
deploy now chowns the store; a manual rsync needs the `chown` above.

Verified: the manifest and all 40 files served through `files.idfon.net` with
the right sizes, MISS → HIT, immutable caching. Remaining: the fresh-install
device E2E (`docs/voice-side-channel.md`), which needs a physical iPhone.

## Not built yet

- Upload retries/resume and `Range` downloads.
- A self-service abuse-report UI (takedown is operator-driven and sticky).
- Per-owner upload credentials: with one shared token the edge cannot tell
  publishers apart; that is a deliberate limit of the current no-paid-tier
  product.
