# Relay configuration: selection at runtime, never compiled in

Relay selection — which relays an endpoint uses — is **never hardwired into a
binary**. Every endpoint bind (message transport, call media, blobs) resolves
it at runtime. Precedence is **parameter > configuration > default**, merged
*per field* (the highest source that sets a field wins):

1. **parameter** — per-run input:

   | Surface | Form |
   | --- | --- |
   | `idfond` | `--relay-urls <urls> --relay-token <token> --relay-only` |
   | `idfon` CLI | same flags (global; forwarded to an auto-started daemon) |
   | iOS / mac app | launch args `-relayurls <urls> [-relaytoken <token>] [-relayonly]` — a per-run override, never persisted |
   | C-FFI | `idfon_relay_settings_set(urls, token, only)` — what the apps call for their in-process endpoints |
   | environment | `IDFON_RELAY_URLS` / `IDFON_RELAY_TOKEN` / `IDFON_RELAY_ONLY` — the bottom of the parameter tier (headless processes, scripts, tests). Environment variables are not a sufficient channel for the apps: they want a persisted setting plus a launch-arg override. |

2. **configuration** — the persisted setting:

   - the apps' **Relay** settings (iOS: peer-list screen, mac: menu sheet),
     stored in `UserDefaults` and applied at process start;
   - `~/.idfon/relay.conf` for headless daemons/CLI:

     ```
     # urls: comma-separated https://… relay URLs (overrides the N0 set)
     urls=https://relay.example:8443
     # token: shared bearer token; leave unset for allowlist / HTTP-callout relays
     token=…
     # only: 1 = relay-only — drop IP transports (enterprise NAT / tests)
     only=0
     ```

3. **default** — the N0 public relay set (the iroh preset). Out of the box
   nothing is configured and every peer runs on N0.

Field semantics: `urls` is a comma-separated `https://…` list; an empty or
unparseable list falls back to the default map. `token` applies only with a
custom map (`shared_token` relays; prefer relays that authorize endpoint ids
or call an auth service — those need no client token, and a token baked into a
binary is extractable and cannot be revoked per device, so provision it at
runtime). `only` (relay-only) is sticky across sources and orthogonal to the
map: it drops IP transports so the endpoint publishes no direct addresses.

Worked examples (per field):

- config file sets `urls` + `token`, run with `idfond --relay-only` → the
  configured relay is kept and forced relay-only.
- config file sets `urls`, `IDFON_RELAY_TOKEN` is exported → file URLs with
  the env token.
- app settings set `urls`, launch passes `-relaytoken X` → settings URLs with
  token `X` for that run only; the next launch uses the settings again.

## What each process does

| Process | Configuration | Parameter |
| --- | --- | --- |
| `idfond` | `~/.idfon/relay.conf` | `--relay-…` flags, `IDFON_RELAY_*` |
| `idfon` CLI | (its daemon's) | `--relay-…` flags, forwarded to the daemon it auto-starts |
| mac app | **Relay** settings (UserDefaults) | launch args; passed to the spawned `idfond` as flags and to the app's in-process media endpoints via the FFI setter |
| iOS app | **Relay** settings (UserDefaults) | launch args; the in-process daemon + media endpoints via the FFI setter |

The resolution itself lives in one place, `idfon_core::relay`
(`crates/idfon-core/src/relay.rs`): `resolve()` (precedence),
`endpoint_builder()` (the N0 preset + resolved selection). Every bind site
uses it — `idfon-core::transport`, `idfon-media` live endpoints, the
`iroh-c-ffi` media/blob endpoints, `idfon-daemon`'s blob provider, the
`eve-idfon` blob endpoints. The FFI `EndpointConfig` enum stays
`Disabled|Default`: `Default` resolves the process's selection at bind time,
so no relay map crosses the C ABI and nothing is compiled in.

## Why the vendored libs matter

The apps link prebuilt Rust artifacts (`ios/Vendor/…/libiroh_c_ffi.a`,
`mac/Vendor/libiroh_c_ffi.dylib`, staged by `ios/build-deps.sh` /
`mac/build-deps.sh`). A change in `idfon-core` reaches the apps only after
those scripts re-stage the libs — see `docs/build.md`. The relay selection
above is read at runtime, so once the libs are current, changing relay needs
**no rebuild**: settings, a launch arg, a flag, or `~/.idfon/relay.conf`.
