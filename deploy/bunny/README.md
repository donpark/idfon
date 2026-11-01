# bunny.net in front of the durable files

Provisioning for the paid durable-files tier (`docs/durable-files.md`): a
bunny.net pull zone whose origin is the droplet's `idfon-edge`, with the custom
hostname `files.idfon.net`.

```
client ── https://files.idfon.net/sha256/<hash> ──> bunny edge (cache)
                                                     └─ miss ─> https://idfon.net/sha256/<hash>
                                                                (idfon-edge files store)
```

Uploads (`idfon publish`) stay pointed at `IDFON_EDGE_URL` (the droplet); the
CDN is the read path only.

## Run

Both deploy scripts read `deploy/digitalocean/.env` (gitignored, mode 600):
put `BUNNYNET_API_KEY=...` there — plus `DIGITALOCEAN_API_KEY=...` to have the
CNAME created too — and no shell export is needed:

```sh
deploy/bunny/setup.sh            # create/converge
deploy/bunny/setup.sh --check    # read-only report
```

A one-off `BUNNYNET_API_KEY=... deploy/bunny/setup.sh` still wins over the file.
This also works for agent/T3 Code sessions, which do not inherit your login
shell; the file is read by the script, not the environment.

The script is idempotent. With `DIGITALOCEAN_API_KEY` set (and `doctl`
installed) it also creates/updates the `files` CNAME at DigitalOcean; otherwise
it prints the record to add. The free certificate is requested once the CNAME
resolves to bunny.net — re-run if the first run reports it is not issued yet.

| Env | Default |
| --- | --- |
| `BUNNYNET_API_KEY` | required (Account → API Key) |
| `IDFON_BUNNY_ZONE` | `idfon-files` (also the `<zone>.b-cdn.net` name) |
| `IDFON_EDGE_ORIGIN` | `https://idfon.net` |
| `IDFON_FILES_HOST` | `files.idfon.net` |
| `IDFON_DOMAIN` | `idfon.net` (for the CNAME record) |
| `DIGITALOCEAN_API_KEY` | optional, enables the DNS step |

## Why these settings

- **Smart Cache OFF.** Smart Cache *restricts* caching to a known extension
  list. Content URLs are extensionless `sha256/<hash>` paths, so it would make
  every download an origin hit. Off, bunny caches any response with cacheable
  headers — which is exactly what the edge sends.
- **Cache overrides = -1 (no override; `0` means "cache for 0 seconds").**
  The edge sends
  `max-age=<remaining>` for a rented object (so the CDN cannot outlive the
  rental), `immutable` for a permanent one, and `no-store` for mutable names
  (`bundle.json`). No purges are needed.
- **Origin is the droplet, HTTPS verified.** The wildcard cert covers
  `idfon.net` and `*.idfon.net` (`deploy/digitalocean/acme-issue.sh`), so the
  apex origin validates.
- No referrer/hotlink rules: app and server downloads send no `Referer`.

Optional, dashboard only: **Origin Shield** (one origin pull per object instead
of one per POP) is worth it for the ~160 MB model packs; the script leaves it
off so it does not silently add cost.

## Point the apps at the CDN

The baked-in `PhononTtsEngine.defaultPackURL` is
`https://idfon.net/models/phonon-31m/`, which bypasses the CDN. Change it (both
apps) to `https://files.idfon.net/models/phonon-31m/`, or set
`IDFON_PHONON_PACK_URL` for a build/test run. The edge serves `/models/...` as
an alias of the same store, and the pack's relative `sha256/<hash>` paths stay
correct under either host.

## Notes

- bunny Token Authentication (signed URLs) is **zone-wide**: enabling it breaks
  the public pack as well. A public/private mix needs a second pull zone or
  our own signing in the edge.
- Rollback without app changes: point `files.idfon.net` at the droplet's
  reserved IP (an A record; the wildcard cert covers the name) and the edge
  serves the same paths directly.
- The API key is account-scoped. Use a revocable/scoped key if bunny's
  account settings allow it, and keep it out of git (`deploy/digitalocean/.env`
  is gitignored if you want one file for both scripts).
