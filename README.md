# Idfon

> **Status:** experimental, pre-release. Distributed via npm with prebuilt
> binaries for macOS (arm64, x64) and Linux (x64, arm64).

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

**npm**:

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
state persists across invocations. Auto-started daemons exit after 10 minutes
with no connected clients and restart on the next command; `idfon shutdown`
stops one immediately.

Everything you share is addressed by a **capability ticket** — a
self-authenticating URL like `blobabzoy2eok…`. Whoever holds a ticket can
fetch that one thing; holding nothing grants nothing. No directory, no
registry, no account.

### Staying reachable (online vs offline)

The daemon is your presence on the iroh network — it holds the endpoint,
relay connection, and receivers. One question decides if you're online:
**is idfond running?**

- **Online:** the Idfon.app is open, or you've started a daemon that doesn't
  idle out: `idfon --keep-alive <any command>`.
- **Offline:** app closed and no keep-alive daemon. After plain CLI use, the
  daemon lingers up to 10 minutes with no clients before exiting on its own;
  run `idfon shutdown` to be offline immediately.
- When you're offline, senders get an explicit delivery failure and can
  resend. Messages that arrive while the daemon is up are stored by it and
  waiting for you (`recv`, `events`) — nothing is silently dropped.

**CLI and app coexist.** Both are clients of the same daemon: they share one
socket and one profile, so identities, peers, and events are the same on both
sides. Either may start the daemon — the other connects to it — and neither
stops one it didn't start. Each install carries its own `idfond` (npm ships
it next to `idfon`; the app bundles one), so upgrade both together: a daemon
serving a client with a mismatched protocol version fails loudly, not
silently.

---

## CLI

Twelve verbs. One mental model:

- **Peerless** — you address content by ticket: `put`/`get`.
- **Peer-directed** — you address a person: `send` (they receive via `recv`).
- Everything is stdin/stdout friendly and scriptable; `--json` gives
  machine-readable envelopes on every verb.

Global options (valid on every verb): `--socket <PATH>` (daemon socket,
default `/tmp/idfon/idfond.sock`), `--identity <ID>`, `--json`,
`--keep-alive` (auto-started daemon never idles out — see
[staying reachable](#staying-reachable-online-vs-offline)).

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

# signaled file: bob runs `recv`, which writes the bytes directly
idfon send bob --file notes.pdf
idfon recv --out notes.pdf       # on bob's side; writes the received file

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
idfon send --stream --list
idfon send --stream --stop <publisher-id>
```

Stream options: `--seconds` (capture window / give-up timeout), `--wait`
(give up if nobody calls within N seconds), `--loop` (repeat source,
broadcast only), `--no-relay` (forbid relayed connections — LAN/direct only).

The two live forms differ in who may listen. A broadcast ticket is a bearer
capability — anyone holding it tunes in, no peer setup required. A 1:1 call
is identity-scoped: it exists only for the session, blocks until hangup, and
prints no ticket by design. `get TICKET` consumes both kinds: blob tickets
fetch bytes, `iroh-live:` tickets capture live audio.

### Identity and peers

```sh
idfon identity list              # identities are local; create with `identity create NAME`
idfon identity use work
idfon peer list
idfon peer add <ref> --name bob  # ref = endpoint id or endpoint addr ticket
idfon peer status bob            # connectivity: direct, relayed, offline
```

### Capabilities

Idfon doesn't auto-trust anyone. Grants live on YOUR daemon and gate YOUR
side of each peer channel — `message.send` lets you send to the subject,
`message.receive` lets you receive from them. SUBJECT is the peer's endpoint
id (public key), not the peer name. Check, allow, or hand out a one-shot
ticket:

```sh
idfon access check --subject <peer-endpoint-id> --capability message.receive
idfon access allow --subject <peer-endpoint-id> --capability message.send
idfon access ticket --subject <peer-endpoint-id> --capability message.receive --expires-at 2026-12-31
```

### Observability

Message events (chat, signaled transfers) are observable — poll, follow, or
block:

```sh
idfon status                     # daemon state + endpoint ticket
idfon events --follow            # message events as they happen
idfon wait --type message.received --timeout-ms 60000   # block until a matching event
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
voice notes, mailbox, and per-capability policy controls. **Prototype — still
in early development and incomplete.** It tracks the daemon protocol but
is not yet a release-quality product; see
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
