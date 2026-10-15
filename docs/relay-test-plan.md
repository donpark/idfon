# Relay auth test plan (hand-off)

Executable plan for verifying the relay access work (`docs/relay-auth.md`).
Written so a tester who has not read the design thread can run it top to
bottom. Run L0 always; L1 before any deploy; L2 once per relay/iroh upgrade;
L3 at each production deploy. Record results as pass/fail per case id.

**Components under test**

| Component | Where | Entry points |
| --- | --- | --- |
| Auth service | `deploy/relay-auth/server.mjs` | `POST /check`, `/owner/*`, `/enroll`, `/refresh` |
| Ops/test CLI | `deploy/relay-auth/ctl.mjs` | `enroll-owner`, `mint-grant`, `enroll-grant`, `refresh`, `admit`, `revoke`, `revoke-ticket`, `entries`, `check` |
| Grant contract | `crates/idfon-core` `issue_relay_grant` + `ticket_unsigned` | golden vector, both languages |
| Deploy wiring | `scripts/deploy-digitalocean.sh`, `deploy/digitalocean/compose.relay.yaml` | `IDFON_RELAY_AUTH=1` mode |

**Not under test yet** (see `docs/relay-auth.md` §6): daemon hooks (owner
bootstrap / admit at `peer.add`), grant delivery at pairing, per-identity
relay config, app UI for `auth_denied_reason()`. Cases that need them are
marked **[manual stand-in]** — they use `ctl.mjs` in place of the daemon.

**Fixtures.** Any 64-hex seed stands in for an `identity-<id>.key`:
`openssl rand -hex 32 > identity.key`. Endpoint ids are 64-hex (any value
works at the service level; real ones come from the daemon's `state.json`).
"the service" below means:

```sh
IDFON_RELAY_ISSUERS=<owner pub hex> IDFON_RELAY_AUTH_TOKEN=dev-bearer \
IDFON_RELAY_ADMIN_TOKEN=dev-admin IDFON_RELAY_AUTH_DATA=/tmp/relay-auth-state.json \
  node deploy/relay-auth/server.mjs          # logs: check <id> allow|deny
C() { node deploy/relay-auth/ctl.mjs --base http://127.0.0.1:9090 "$@"; }
```

`enroll-owner`/`mint-grant` derive the owner public id from `--key-file`.

---

## L0 — automated (run every change; ~15 s)

```sh
node --test deploy/relay-auth/
cargo test -p idfon-core -p idfon-protocol
```

| ID | What it pins | Expected |
| --- | --- | --- |
| RA-L0-01 | Rust↔Node golden-vector signature match *and* remint | pass |
| RA-L0-02 | grant rejection: untrusted issuer / tamper / expiry | pass |
| RA-L0-03 | owner-challenge single use (replay denied) | pass |
| RA-L0-04 | token rotation kills the old token | pass |
| RA-L0-05 | revoke cascade: ticket → entry → tokens | pass |
| RA-L0-06 | owner scoping + fail-closed `/check` | pass |

## L1 — service behavior (local, no relay)

| ID | Steps | Expected |
| --- | --- | --- |
| RA-L1-01 | start the service without `IDFON_RELAY_ISSUERS`, then without `IDFON_RELAY_AUTH_TOKEN` | exits 1 with a clear message (fail closed) |
| RA-L1-02 | `C check --endpoint <id> --bearer dev-bearer` on a fresh state; repeat with `--bearer wrong` | 403 both; log shows `deny` |
| RA-L1-03 | `C enroll-owner --key-file identity.key`; `C check --endpoint <id> --bearer dev-bearer` | owner token JSON; then `200 true` |
| RA-L1-04 | re-POST the *same* `/owner/enroll` body twice (replay the nonce) | first 200, second 403 `challenge missing or expired` |
| RA-L1-05 | `C admit --token $OWNER --endpoint <caller> --label alice`; `C check`; `C revoke --token $OWNER --endpoint <caller>`; `C check` | 200 → 403; revocation is immediate, service never restarts |
| RA-L1-06 | **[manual stand-in]** `C mint-grant --key-file identity.key --endpoint <caller> --ticket t1 > g.json`; `C enroll-grant --grant g.json` | non-owner token + `endpoint_id` = subject |
| RA-L1-07 | `C check --endpoint <caller> --bearer dev-bearer` after L1-06 | `200 true` (grant bootstrap admitted the subject) |
| RA-L1-08 | `C refresh --token <non-owner>`; retry the old token | new token returned; old token → `non-owner token required` |
| RA-L1-09 | call `POST /owner/entries` with a *non-owner* token | 403 (caller token is not management authority) |
| RA-L1-10 | `C mint-grant … --expires 2020-01-01T00:00:00Z`; `C enroll-grant` | 403 `grant expired` |
| RA-L1-11 | `C mint-grant …`, then edit the JSON (change `subject` or `ticket_id`) and `enroll-grant` | 403 `grant signature invalid` |
| RA-L1-12 | `C revoke-ticket --token $OWNER --ticket t1`; `C check --endpoint <caller>` | 403; the non-owner token from L1-06 also dead on `/refresh` (cascade) |
| RA-L1-13 | two owners (two seeds, both in `IDFON_RELAY_ISSUERS`): owner B `revoke`s owner A's admitted caller; then admin bearer does the same | B → 403 `entry belongs to another identity`; admin → 200 |
| RA-L1-14 | `C check` with an UPPERCASE hex `--endpoint` for an admitted lower-case entry | `200 true` (ids normalize) |
| RA-L1-15 | restart the service with the same `IDFON_RELAY_AUTH_DATA`; `C check` | still `200 true` (state persists) |
| RA-L1-16 | `C check --endpoint <id>` with entry's lease in the past (set `IDFON_RELAY_LEASE_DAYS=0` on a throwaway state) | 403 (lease enforcement) |

## L2 — with a real relay + a real endpoint

Setup: the service on :9090, then stock relay in dev mode:

```sh
cat > /tmp/relay-dev.toml <<'EOF'
enable_relay = true
access = { http = { url = "http://host.docker.internal:9090/check", bearer_token = "dev-bearer" } }
EOF
docker run --rm -p 3340:3340 -v /tmp/relay-dev.toml:/config/config.toml \
  n0computer/iroh-relay:v1.3.0 --dev --config-path /config/config.toml
# then any idfon daemon homed on it (its home-relay connection alone trips /check):
IDFON_RELAY_URLS=http://127.0.0.1:3340 idfond --data-dir /tmp/idfon-test
```

| ID | Steps | Expected |
| --- | --- | --- |
| RA-L2-01 | daemon starts with no admission | service log `deny`; the endpoint never settles on the relay (reconnect backoff visible in daemon logs) |
| RA-L2-02 | `C enroll-owner --key-file <data>/identity-<id>.key` (pass `--endpoint` if the identity has a separate `endpoint-<id>.key`) | log flips to `allow`; endpoint goes online without a daemon restart |
| RA-L2-03 | `C revoke` while the endpoint is connected, then force a reconnect (daemon restart or network blip) | open connection survives until it drops (revocation bites at the *next* connect — record the observed window); new connect denied |
| RA-L2-04 | two daemons, owner + admitted caller (L1-06 grant): message send caller → owner over relay | delivered; `/check` shows `allow` for both ids. **Deferred to L3** (needs a daemon pair or the bench; L1 covers multi-endpoint admission logic) |
| RA-L2-05 | regression, N0 door stays open: relay with `access = { shared_token = ["s3cret"] }` + daemon with `IDFON_RELAY_TOKEN=s3cret` | connects (this is the `RelayConfig::with_auth_token` seam). **Deferred to L3-03** (the production relay runs shared_token today, so the bench is the live regression; the seam itself is iroh's `test_endpoint_relay_auth_token`) |
| RA-L2-06 | regression: daemon with `IDFON_RELAY_URLS` **unset** | uses iroh's default (N0) relays; a message between two such daemons still delivers |

## L3 — production smoke (each deploy)

| ID | Steps | Expected |
| --- | --- | --- |
| RA-L3-01 | `IDFON_RELAY_AUTH=1 IDFON_RELAY_ISSUERS=<keys> pnpm deploy:do:relay` | deploy completes; `curl https://relay.<domain>:9443/healthz` → `{"ok":true}`; firewall has 9443; `docker compose ps` shows `relay-auth` |
| RA-L3-02 | admit the edge's endpoint id with the curl the deploy prints | edge's relay connection settles (edge logs) |
| RA-L3-03 | `scripts/relay-bench.sh` | relayed rows match baseline (sfo3: ~127 ms p50, 0 stalls); no `deny` in the relay-auth log for bench endpoints |
| RA-L3-04 | revocation drill: `C revoke` a live contact endpoint → that contact dials → re-admit → redial | denied → allowed; **no relay restart, no client change** between the two |
| RA-L3-05 | rollback drill: redeploy with `IDFON_RELAY_TOKEN` mode (or `IDFON_RELAY_ALLOWLIST`) instead | service stops (auth profile off), relay keeps working under the old mode |

## Gotchas from the first full run (all hit, all fixed — do not re-derive)

- **Wire header name is `x-iroh-nodeid`**, not `x-iroh-node-id` (i.e.
  `X-Iroh-NodeId` lowercased). Tests originally set the wrong name on *both*
  sides and stayed green — only a live relay caught it. Service accepts both
  spellings now.
- **Docker Desktop does not share `/var/folders`** (where `mktemp -d` lands).
  A `-v` mount from there silently yields no file, and iroh-relay's
  `Config::load` then falls back to **defaults (`access: AllowAll`)** instead
  of failing. Put the config under `$HOME` and verify with `RUST_LOG=debug`
  that the startup dump says `access:HttpAccess{…}`.
- **`--dev` does not touch `access`** (only TLS/port); the dump printout
  (`docker logs relay-l2 | grep access:`) is the ground truth for what is
  enforced.
- **Rebuild `target/release/idfon-edge`** before using it as the test
  endpoint — a stale binary silently ignored `IDFON_RELAY_URLS` and homed on
  N0 (`cargo build --release -p idfon-edge`, ~90 s; workspace-only, no
  vendored c-ffi chain).
- `ctl.mjs` needs explicit `method: "POST"` semantics for body-less POSTs —
  already handled; if you add commands, don't fall back to GET.

## Pass criteria

- L0 all green (required for every commit touching `deploy/relay-auth/` or
  `ticket_unsigned`).
- L1 all green before any deploy that changes the service.
- L2 green before an iroh or relay-image version bump.
- L3 green for the deploy to be declared done; RA-L3-04 is the acceptance
  test for the whole feature (per-client revocation without restarts).

## Known gaps (accepted, tracked in `docs/relay-auth.md` §6)

- Caller-side grant *delivery* at pairing is not built; L1-06/L2-04 use
  `ctl.mjs` as a stand-in for the daemon.
- Revocation latency = connection lifetime (RA-L2-03); if the observed window
  matters, a kick-on-revoke needs a custom relay (explicitly out of scope).
- iOS background freezing can delay non-owner token refresh; TTLs (7/30 days)
  are sized so a frozen device keeps its lease across normal use.
- The relay callout path (`/check`) has no rate limiting; it is reachable only
  from the relay (bearer + docker network) and 9443 only serves the owner/
  enroll APIs.

## Rollback

Nothing in the codebase forces this mode on: relays run auth mode only when
`IDFON_RELAY_AUTH=1`. Reverting a deployment = redeploy in `IDFON_RELAY_TOKEN`
or `IDFON_RELAY_ALLOWLIST` mode (RA-L3-05); the state file
`/srv/idfon-edge/relay-auth/data/state.json` is inert and can be archived or
deleted.
