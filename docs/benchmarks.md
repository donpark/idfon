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
only `RELAY_MODE_DISABLED|DEFAULT` and no path query. A custom relay map,
auth token, and relay-only now reach the FFI endpoints through the process-level
relay selection instead (`idfon_relay_settings_set`, `docs/relay-config.md` —
`RELAY_MODE_DEFAULT` resolves it at bind time), so a TS bench no longer needs
them in `EndpointConfig`; a path query remains platform work in
`crates/iroh-c-ffi`, not vertical work.

## 2. Voice-turn stages — `voice-report` tool / `scripts/voice-latency-report.sh`

`VoiceAgentSession` writes one marker per completed turn (iOS + mac apps):

```
idfon-auto: voice-agent: turn=3 asr_gap_ms=1240 listen_ms=2100 reply_ms=870 speak_ms=2600 total_ms=6810
```

| Field | Stage |
| --- | --- |
| `asr_gap_ms` | **turn detection**: recognizer's last update → commit — the `VoicePromptSegmenter`'s end: the text gap (1.2 s mac / 0.8 s iOS) or, with `IDFON_QUIET_END=1`, the quiet clock (≈240 ms of measured quiet after text settles 150 ms); + up to 100 ms tick; ~0 on a recognizer final |
| `listen_ms` | the listening window for the caller's utterance |
| `reply_ms` | send → agent reply arrival: **network + agent turn** (§1 measures the network share) |
| `speak_ms` | TTS synthesis + playback, includes `speak()`'s ~800 ms post-roll hold |
| `total_ms` | the whole turn |

A second marker explains the end: the quiet clock from RealtimeVAD (MIT), a
10 ms block RMS compared with the learned room noise level, fed the same mic
audio as the recognizer.

```
idfon-auto: quiet-clock: via=clock pauses=6 long_resumed=1 max_resumed_ms=310 end_quiet_ms=240 commit_gap_ms=810
```

`via` is `clock` (measured quiet), `gap` (text-gap fallback), `final`
(recognizer final) or `force` (turn model). `pauses` counts speech-off events
in the turn, `long_resumed` the ones that resumed after ≥ 240 ms — a wrong
early end — and `max_resumed_ms` the longest such gap. `end_quiet_ms` is the
quiet measured at commit; `commit_gap_ms` is the recognizer-text lag.

The clock's early end is **off by default** (`IDFON_QUIET_END=1` enables it).
Replaying the `endpoint-audit-2026-11-06`/`2` clips (40 real 6 s call excerpts,
16 kHz stereo channel 0) through the shipping `QuietClock`, primed with each
clip's 10th-percentile room level: a ≥ 240 ms quiet run starts within 1.5 s
after the candidate mark in **8 of 20 non-endpoint clips** and in 1 of 20
endpoint clips. The rule is not yet a safe turn end on real audio; the
text-gap path stays. Reproduce with `ios/Checks/QuietClockReplay` or watch
`long_resumed` on a live call.

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

### Answer time (time to "answered" + greeting)

The apps write one `answer` marker per answered call at the answered cue (mac
+ iOS `VoiceAgentSession`), the stage that gates "time to answer":

```
idfon-auto: voice-agent: answer label=call peers_ms=12 rotate_ms=40 asr_ms=310 tts_ms=80 sleep_ms=1500 director_ms=620 greet_ms=1900 total_ms=3200
```

| Field | Stage |
| --- | --- |
| `peers_ms` | contact resolution (daemon `peers` RPC) |
| `rotate_ms` | session-rotate message send |
| `asr_ms` | recognizer start (model load / first-use compile) |
| `tts_ms` | reply-voice load (iOS only) |
| `sleep_ms` | fixed hydration settle (iOS only, 1.5 s) |
| `director_ms` | on-device AFM director load + warm (proxy calls) |
| `greet_ms` | the greeting turn round trip — network + agent turn (model); the floor of "time to answer" |
| `total_ms` | ringback start → answered cue (mac runs the greet concurrently with `asr_ms`/`director_ms`, so stages do not sum to the total) |

Absent keys are stages that did not run (e.g. no `rotate_ms` for an on-device
agent). `label=call` is the app; the greet bench below emits its own labels.

### Greet floor — `node agents/bench/lib/bench.ts greet`

The model-free floor of `greet_ms`: N greet-style text round trips through a
real `eve-idfon` holder with an instant-reply fixture agent (the
`scripts/eve-holder-e2e.sh` shape, driven from TS). Measures two message
transports (invite + reply), holder ingest, and the agent-IPC hop — never
model time. The first exchange is its own `greet-floor-cold` sample: a send
racing the endpoint's first pkarr publish fails and DNS-negative-caches the
peer's endpoints, poisoning fast retries (see §1's `first` column: 110 ms–1.6 s
cold vs 10–230 ms warm on one host, and relay-only can exceed the 30 s
operation timeout). The bench settles 3 s after holder start (`GREET_SETTLE_MS`)
so samples measure the exchange, not the race.

```sh
node agents/bench/lib/bench.ts greet --count 10   # markers + summary
```

### Baselines — regression check

`report` turns any marker log (turn + answer markers) into tables and can
compare against a stored baseline, failing (exit 1) when a metric's p95
regresses past the budget (default +25%):

```sh
scripts/voice-latency-report.sh call.log --baseline agents/bench/baselines/voice-baseline.json
… | scripts/voice-latency-report.sh --write-baseline agents/bench/baselines/voice-baseline.json
```

The committed baseline (`agents/bench/baselines/voice-baseline.json`) is
seeded from the greet floor; re-seed it from a captured call log to add the
`call.` (app answer path) and turn metrics, then every later capture checks
against it. History rows stay in the gitignored `bench-results/`
(`greet-<date>.jsonl`), same as §1.

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
