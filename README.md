# Idfon

> **Status:** experimental, pre-release. The npm install (`npx idfon`) lands
> when this repo goes public; until then, build from source.

Idfon is a peer-to-peer communication system built on
[iroh](https://www.iroh.computer) — direct, encrypted connections between
endpoints, no servers, no accounts, no directory. It is not a phone or
video-chat app: it is a set of independently grantable **capabilities** (chat,
async voice, live audio, data transfer) that you hand out piece by piece, with
local policy deciding how each one reaches you.

The product model is described in the
[Communication Model](docs/communication-model.md); the developer entry point
is the CLI.

## Install

**npm** (after public launch):

```sh
npx idfon status        # no install — downloads the prebuilt binary
npm install -g idfon    # or install it
```

Prebuilt binaries for macOS (arm64, x64) and Linux (x64, arm64) — see
[npm distribution](docs/npm-distribution.md). Windows is not supported yet.

**From source** (Rust toolchain):

```sh
cargo build --release -p idfon-cli -p idfond
# binaries in target/release/: idfon (CLI) and idfond (daemon)
```

## How it works

The CLI is a thin client over a local **daemon** (`idfond`, a Unix-socket
service). The first `idfon` command starts the daemon automatically; it holds
the iroh endpoint, peer state, and live sessions, so commands are fast and
state persists across invocations. `idfon shutdown` stops it.

Everything you share is addressed by a **capability ticket** — a
self-authenticating URL like `blobabzoy2eok…`. Whoever holds a ticket can
fetch that one thing; holding nothing grants nothing. No directory, no
registry, no account.

---

## CLI

Twelve verbs. One mental model:

- **Peerless** — you address content by ticket: `put`/`get`.
- **Peer-directed** — you address a person: `send` (they receive via `recv`).
- Everything is stdin/stdout friendly and scriptable; `--json` gives
  machine-readable envelopes on every verb.

Global options (valid on every verb): `--socket <PATH>` (daemon socket,
default `/tmp/idfon/idfond.sock`), `--identity <ID>`, `--json`.

### Content by ticket: `put` / `get`

The bash-pipe primitives. No peer setup, no addressing — the ticket *is* the
address. `put` chunks arbitrary-size input automatically; `get` fetches any
ticket to stdout or a file.

```sh
# store and share: ticket goes to stdout, pipe it anywhere
idfon put --file demo.mp4                       # → blobabzoy2eok…
ticket=$(idfon put --file big.bin) && ssh host "idfon get $ticket > big.bin"

# fetch a ticket you were handed
idfon get blobabzoy2eok… --out demo.mp4
idfon get blobabzoy2eok… > demo.mp4
```

### Peer-directed: `send` / `recv`

`send` is the content verb; what it does depends on its flags, and `PEER`
presence decides 1:1 vs broadcast. `recv` is its counterpart — it blocks
waiting for an incoming push.

```sh
# one-time setup: tell your daemon about the other side
idfon peer add <endpoint-id-or-addr> --name bob

# chat text
idfon send bob --text "lunch?"

# signaled file: bob's `recv` prints the ticket; his `get` fetches the bytes
idfon send bob --file notes.pdf
idfon recv                        # on bob's side; prints the BlobTicket

# stdin works too
tar cz -C src . | idfon send bob --file
```

### Live audio: `send --stream`

Same verb, audio. Broadcast (`PEER` absent) publishes a live stream and prints
its ticket — anyone with the ticket tunes in via `get`. With `PEER`, it's a
1:1 session: `send` blocks until the other side hangs up.

```sh
# broadcast: publish a live stream (reads the wav from --file, repeats it)
idfon send --stream --file audio.wav --loop     # → liveticket…
idfon get liveticket… --out listen.wav           # listeners, on any machine

# 1:1 call: alice calls, bob answers; both block until hangup
idfon send bob --stream --file hello.wav         # alice
idfon recv --stream --seconds 30 --out reply.wav # bob

# manage publishers
idfon send --list
idfon send --stop <publisher-id>
```

Stream options: `--seconds` (capture window / give-up timeout), `--wait`
(give up if nobody calls within N seconds), `--loop` (repeat source,
broadcast only), `--no-relay` (forbid relayed connections — LAN/direct only).

### Identity and peers

```sh
idfon identity list              # identities are local; create with `identity create NAME`
idfon identity use work
idfon peer list
idfon peer add <ref> --name bob  # ref = endpoint id or endpoint addr ticket
idfon peer status bob            # connectivity: direct, relayed, offline
```

### Capabilities

Idfon doesn't auto-trust anyone. Check what a peer may do, grant it, or hand
out a one-shot ticket:

```sh
idfon access check --subject bob --capability message.receive
idfon access grant --subject bob --capability message.send
idfon access ticket --subject bob --capability message.receive --expires-at 2026-12-31
```

### Observability

Every daemon event (transfers, streams, peer changes) is observable — poll,
follow, or block:

```sh
idfon status                     # daemon state + endpoint ticket
idfon events --follow            # stream of events as they happen
idfon wait --type blob.fetch --timeout-ms 60000   # block until a matching event
idfon operation get <op-id>      # async operations: get / wait / cancel
idfon shutdown                   # stop the daemon
```

### Scripting notes

- Exit codes and stdout are stable; `--json` prints the full response
  envelope for anything you'd otherwise parse from human output.
- `put`/`get` are pure stdin/stdout filters — they compose with `ssh`,
  `curl`, `tar`, cron, and CI the way `cat` does.
- `wait` exists so a shell script can block on one event instead of polling
  `events`.

---

## Idfon.app

A native macOS client built on the same daemon ([Native SDK](native/)),
covering the interactive surface the CLI doesn't aim at: live calls,
voice notes, mailbox, and per-capability policy controls. **Experimental** —
it tracks the daemon protocol but is not yet a release-quality product; see
[custom app launch](docs/custom-app-launch.md) for building and signing it.

## Documentation

| Doc | What it covers |
|-----|----------------|
| [Communication model](docs/communication-model.md) | capabilities, policies, privacy model |
| [CLI data transfer & live streaming](docs/cli-data.md) | pipe semantics, chunking, stream protocol |
| [Audio media](docs/audio-media.md) | Rust media layer, codecs, verified status |
| [npm distribution](docs/npm-distribution.md) | how `npx idfon` ships prebuilt binaries |
| [Architecture plan](docs/architecture-plan.md) | implementation plan and current state |
| [Troubleshooting](docs/troubleshooting.md) | known failure modes and fixes |

## Development

```sh
cargo build --release -p idfond -p idfon-cli   # daemon + CLI
scripts/test-rust.sh                           # unit tests
scripts/test-e2e.sh                            # end-to-end: two daemons, real transfers
scripts/stream-e2e.sh                          # live audio end-to-end
```

See [architecture plan](docs/architecture-plan.md) for the crate layout
(`idfon-protocol` → `idfon-core`/`idfon-media` → `idfon-daemon`/`idfond` →
`idfon-client` → `idfon-cli`).

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), like
iroh.
