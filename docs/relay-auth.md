# Relay auth: per-identity relay claiming, grants, and relay-issued tokens

How a self-hosted iroh relay decides who may use it, how callers get admitted,
and how any of it is revoked — without restarting the relay or updating
clients. Companion to `deploy/relay-auth/server.mjs` (the auth service) and
`deploy/digitalocean/README.md` (deployment).

> Status: as-built for the auth service + grant contract; the daemon-side
> enrollment hooks (owner bootstrap at `peer.add`, lease refresh) are the
> follow-up, see §6. `deploy/relay-auth/ctl.mjs` is the manual ops/test
> surface until those hooks land (see §7).

## 1. The topology fact everything rests on

Relayed traffic is carried by the **callee's** relay: the caller connects to
the relay URL in the callee's `EndpointAddr` and sends through it
(`iroh/src/socket/transports.rs` — "we take the relay URL of the remote
address"). Each endpoint keeps a persistent connection to its *home* relay.
There is no relay↔relay forwarding in iroh-relay v1.3.0.

Consequences:

- Your relay's users are **your identities' endpoints** (home clients) **and
  the endpoints of peers who call them** (senders). Both hit the relay's
  access hook on every connection.
- A work identity homed on the employer's relay means every call to that
  identity is carried, metered, and controlled by the employer's relay.
- N0/Iroh-managed relays stay usable: relay choice is per-identity config,
  and client-side relay auth rides iroh's own `RelayConfig::with_auth_token`
  seam (see §5).

## 2. The pieces

| Piece | What it is | Lifetime |
| --- | --- | --- |
| **Claim** | An identity homed on relay `R`; its public key is a trusted issuer of `R` | until unclaimed |
| **Grant** | Signed, caller-bound `CapabilityTicket` (`relay.use`): issuer = owner identity key, subject = caller endpoint id, signed relay URL, expiry, ticket_id | bootstrap / recovery only |
| **Owner token** | Random, stateful, endpoint-bound; minted after the owner signs a single-use challenge | hours (default 12) |
| **Non-owner token** | Same shape; minted when a caller presents a grant | days (default 7), refreshed at half-life |
| **Entry** | The admission record `/check` consults: endpoint id → {role, identity, account, label, ticket_id, lease} | lease (days), extended by refresh/upsert |

The grant is the *long-lived* credential and travels once; the tokens are the
*hot* credential and are scoped, rotatable, and revocable independently. The
relay's handshake already authenticates the connecting endpoint id (TLS key
export), so tokens are useless when stolen — every check is bound to the
endpoint id.

## 3. Flows

**Owner claims the relay (first run).** `POST /owner/challenge` → sign
`idfon-relay-owner/1|<identity>|<endpoint>|<nonce>` with the identity key →
`POST /owner/enroll` → owner token + owner entry. The key must be listed in
`IDFON_RELAY_ISSUERS` (per relay; employer relays list employer-issued
identity keys).

**Caller is admitted.** Two paths, same verification:
- *Owner-side (immediate):* at ticket accept our daemon calls
  `POST /owner/entries` with the caller's endpoint id (optionally the grant,
  for ticket-cascade revocation). The caller needs nothing.
- *Caller-side (fallback):* the caller presents the grant to `POST /enroll`
  and gets a non-owner token; `POST /refresh` keeps its lease alive.

Until the daemon hooks land, `deploy/relay-auth/ctl.mjs` drives all of these
by hand (`enroll-owner` signs the challenge from an `identity-<id>.key` seed,
then `admit` / `revoke` / `revoke-ticket` / `entries` / `check`).

**Revoke.** `DELETE /owner/entries/<endpoint>` or
`POST /owner/revoke-ticket {ticket_id}` — the entry and every derived token
die immediately; the next relay connection is denied. No relay restart, no
client update. A leaked *token* is revoked without touching the grant.

## 4. What the relay itself runs

Stock `n0computer/iroh-relay` (no fork) with

```toml
access = { http = { url = "http://relay-auth:9090/check", bearer_token = "…" } }
```

The callout sends `X-Iroh-NodeId`; the only accepted answer is `200 true`.
Everything else (grant verification, tokens, revocation) lives in the auth
service beside the relay. Wire format detail that matters: the signed bytes
of a grant are serde's canonical JSON of
`{capabilities, conversation, expires_at, issuer, subject, ticket_id[, path_scope][, voice][, relay]}`
with keys sorted **alphabetically** — pinned by the golden vector in
`crates/idfon-core` (`relay_grant_golden_vector`) and `deploy/relay-auth/test.mjs`.

## 5. Keeping N0 / managed relays compatible

- Relay choice is plain config (`IDFON_RELAY_URLS`, unset = iroh defaults).
  Nothing in pairing or messaging assumes our relay or our auth service.
- Client relay credentials use iroh's per-relay `RelayConfig::with_auth_token`
  (`iroh-relay/src/relay_map.rs`) — the same seam a managed-services token
  source (project API key → short-lived endpoint-bound token) plugs into.
  The relay actor reads the token at each connect, so a token source can
  rotate values at runtime.
- Grants are only minted/required for relays running our auth service.
- Surface `Endpoint::auth_denied_reason()` in apps when a relay rejects
  credentials; do not invent a parallel mechanism.

## 6. Follow-ups

- Daemon hooks: owner bootstrap + `POST /owner/entries` at `peer.add`,
  revoke at `peer.remove`, lease refresh loop, per-identity relay config
  (`crates/idfon-core/src/transport.rs` is global `IDFON_RELAY_URLS` today).
- Grant delivery to the caller (signed in/alongside the pairing exchange) so
  the caller-side `/enroll` fallback works.
- Apps: relay settings UI for per-identity relay + `auth_denied_reason()`.

## 7. Testing

`node --test deploy/relay-auth/` covers the contract and the service: the
Rust↔Node golden-vector signature match (and remint), grant rejection paths
(untrusted issuer / tamper / expiry), owner-challenge replay, token rotation,
revoke cascade (ticket → entry → tokens), owner scoping, and fail-closed
`/check`. `cargo test -p idfon-core` covers the Rust half of the vector.

The local loop (no relay needed):

```sh
WORK=$(mktemp -d); openssl rand -hex 32 > $WORK/identity.key   # stand-in for identity-<id>.key
IDFON_RELAY_ISSUERS=<its pub hex> IDFON_RELAY_AUTH_TOKEN=dev-bearer \
IDFON_RELAY_ADMIN_TOKEN=dev-admin IDFON_RELAY_AUTH_DATA=$WORK/state.json \
  node deploy/relay-auth/server.mjs
# elsewhere:
C() { node deploy/relay-auth/ctl.mjs --base http://127.0.0.1:9090 "$@"; }
C check --endpoint <id> --bearer dev-bearer         # 403 — fail closed
C enroll-owner --key-file $WORK/identity.key        # → owner token
C check --endpoint <id> --bearer dev-bearer         # 200 true
C admit --token $TOKEN --endpoint <caller-id> --label alice-phone
C revoke --token $TOKEN --endpoint <caller-id>      # 403 again
```

The server logs every decision (`check <id> allow|deny`). Against a real
relay: run stock `n0computer/iroh-relay:v1.3.0 --dev` with
`access = { http = { url = "http://host.docker.internal:9090/check",
bearer_token = "dev-bearer" } }` in the config and point one daemon at it
(`IDFON_RELAY_URLS=http://127.0.0.1:3340`) — its home-relay connection alone
trips the callout — then watch the log flip after `enroll-owner`. Production:
`IDFON_RELAY_AUTH=1 … pnpm deploy:do:relay`, admit the edge id with the printed
curl, `curl https://relay.<domain>:9443/healthz`, then `scripts/relay-bench.sh`
and the revocation drill (revoke a live contact, redial: denied — no relay
restart, no client change).
