# Benchmarks: relay paths and voice-turn latency

Regular, repeatable measurement for the two latency suspects behind "the voice
agent got slower": **the relay path** (public N0 relays vs the private
`relay.idfon.net`) and **the voice turn itself** (turn detection, agent round
trip, TTS).

The whole vertical is **pure TypeScript** (`agents/bench/` + `lib/`) driving
the prebuilt `idfon`/`idfond` binaries — no Rust toolchain needed
(`docs/npm-distribution.md`: `npm install idfon` ships both per platform).
Third-party agent developers can copy the shape: a vertical is an Eve agent +
`lib/` modules, wrapped by thin scripts.

Three ways to run it:

| Via | What |
| --- | --- |
| **bench Eve agent** (`agents/bench`) | dial the peer, ask for a run; tools do the work, results land in the chat |
| `scripts/relay-bench.sh` / `scripts/voice-latency-report.sh` | thin wrappers over `node agents/bench/lib/bench.ts` |
| `node agents/bench/lib/bench.ts matrix\|rtt\|report …` | direct, for scripting |

## 1. Relay matrix — `relay-matrix` tool / `scripts/relay-bench.sh`

One fresh daemon pair per relay config, paired like `scripts/test-e2e.sh`, and
measured on the **real message path** — exactly what a chat/voice turn pays:

| Column | Meaning |
| --- | --- |
| `msg p50/p95/max` | `send --text` → delivery ack: fresh QUIC connection + message envelope + ack, per message (the transport opens a connection per message) |
| `stalls` | messages that never acked in 30 s (excluded from percentiles) |
| `Mbps` | chunked blob transfer + delivery (`send --file`) |

Configs: `n0`, `n0-relay-only`, `idfon` (`https://relay.idfon.net:8443`),
`idfon-relay-only`. The `*-relay-only` rows force the relay path
(`IDFON_RELAY_ONLY` drops IP transports — the same knob the apps honor), so
the relay comparison is honest even on one host; other rows take whatever path
iroh picks (usually direct on one host).

```sh
scripts/relay-bench.sh --quick        # short smoke run
scripts/relay-bench.sh                # full: 10 messages + 1 MB blob per config
scripts/relay-bench.sh rtt --to PEER  # measure one peer through your daemon
```

Rows append to `bench-results/relay-<date>.jsonl` (gitignored); run it
regularly and diff. `rtt` measures an already-running daemon's real config —
for cross-network numbers run it between two hosts (e.g. Mac ↔ the edge box),
once per relay config.

**Known gaps.** (a) No selected-path introspection (`ip` vs `relay`) in the
daemon CLI yet — the forced rows are honest by construction, but a natural row
cannot say which path won. (b) The bare FFI (`irohnet.h`) is not enough to
build this benchmark in TS on top of iroh directly: its `EndpointConfig` has
only `RELAY_MODE_DISABLED|DEFAULT` (no custom relay map, no auth token, no
relay-only) and no path query. Extending it is platform work in
`crates/iroh-c-ffi`, not vertical work.

## 2. Voice-turn stages — `voice-report` tool / `scripts/voice-latency-report.sh`

`VoiceAgentSession` writes one marker per completed turn (iOS + mac apps):

```
idfon-auto: voice-agent: turn=3 asr_gap_ms=1240 listen_ms=2100 reply_ms=870 speak_ms=2600 total_ms=6810
```

| Field | Stage |
| --- | --- |
| `asr_gap_ms` | **turn detection**: recognizer's last update → commit — the `VoicePromptSegmenter` silence gap (~1200–1500 on the fallback path, + up to 300 ms tick; ~0 on a recognizer final) |
| `listen_ms` | the listening window for the caller's utterance |
| `reply_ms` | send → agent reply arrival: **network + agent turn** (§1 measures the network share) |
| `speak_ms` | TTS synthesis + playback, includes `speak()`'s ~800 ms post-roll hold |
| `total_ms` | the whole turn |

```sh
scripts/voice-latency-report.sh call.log    # captured marker log
… | scripts/voice-latency-report.sh         # stdin (devicectl --console output)
scripts/voice-latency-report.sh --self-test
```

Capture sources: `xcrun devicectl device process launch --console com.idfon.ios --
-voiceagent <peer> <turns>` on iPhone (same capture style as
`scripts/ios-device-test.sh`), or the mac app's stderr (`-voiceagent`). Send
the log to the bench agent instead and it does the same parse. Older logs
without `turn=` markers still report their `listen_ms` values.

Reading it: `asr_gap_ms` dominating → the turn-detection heuristic (its
constant costs are visible by design: 1.2 s segmenter gap + 800 ms post-roll);
`reply_ms` dominating → compare with §1 (relay RTT + stalls); `speak_ms`
dominating → TTS backend (Kokoro vs Apple) or device load.

## 3. The bench peer — `agents/bench`

A dialable measurement service (pair it like any agent contact:
`pnpm agent start bench`, then the printed `pnpm pair`/`-pair` commands). Tools:

- `relay-matrix` — the §1 matrix from the agent's host
- `msg-rtt` — §1's `rtt` against one peer
- `voice-report` — §2's parse of an attached/pasted log

With no `EVE_IDFON_MODEL` the agent runs a deterministic mock model that
answers `BENCH-PING <tag>` with `BENCH-PONG <tag>` immediately — so timed
request/reply pairs between two bench peers measure transport + holder, never
model latency. Voice calls get a one-sentence verdict; the table goes to chat.

## Relay access matters

`relay.idfon.net` runs with `shared_token` access (`deploy/digitalocean/README.md`
also documents allowlist / HTTP callout; an open relay is only ever deployed
with the explicit `IDFON_RELAY_OPEN=1` — the deploy is fail-closed). Clients
present the token at runtime:

- daemons / bench: `IDFON_RELAY_TOKEN` (the bench scripts fall back to the
  local secret file `~/.idfon/relay-token`, which the deploy tooling shares
  with `scripts/deploy-digitalocean.sh` for consistent redeploys)
- iOS/mac apps: the token field in Relay Settings (`RelaySettings.token`), or
  on iOS at launch for automation: `-relayurls <url> [-relaytoken <token>]
  [-relayonly]` (persists like the settings UI; applied before the daemon
  starts)

A client the relay does not admit gets `The relay denied our authentication
(not authorized)` (client-side; the relay logs denials only at debug) and **no
relay at all** — and since `IDFON_RELAY_URLS` replaces the N0 relays, such a
peer is direct-only with stalling connects. Symptom check: grep daemon logs
for `denied our authentication`. The old allowlist mode is documented but
brittle here: the bench spawns fresh endpoint keys per run and third-party
agents bring their own, so an allowlist can never admit them.
