# Idfon

Idfon is a peer-to-peer communication and data-transfer system built on
[iroh](https://www.iroh.computer). It provides a local daemon, a CLI, and
native clients. Idfon stores identities and peer state on the local machine.
Connections may use direct paths, discovery, or relays supplied by iroh.

> **Status:** experimental and pre-release. The CLI is available as an npm
> package. Native clients are usable for development. The iOS ↔ Eve text-agent
> demo passes end-to-end tests on a physical iPhone. Voice/STT/TTS remains a
> separate follow-up.

## CLI installation

The npm package includes prebuilt binaries for macOS (arm64, x64) and Linux
(x64, arm64). The launcher requires Node.js 18 or later.

```sh
npx idfon status
npm install --global idfon
```

Windows is not supported yet. To build from source, install Rust and run:

```sh
cargo build --release -p idfon-cli -p idfond
```

The resulting binaries are `target/release/idfon` and
`target/release/idfond`.

## Daemon

`idfon` is a client for `idfond`, which owns the iroh endpoint and persistent
local state. The CLI starts `idfond` when needed and connects to it through a
Unix socket. By default the socket is `/tmp/idfon/idfond.sock`.

An automatically started daemon exits after its idle timeout. Use
`--keep-alive` to disable that behavior, or run `idfon shutdown` to stop it.
The daemon is also used by the native clients, so the CLI and an app can share
an identity and peer state.

## CLI

Run `idfon --help` for the complete command list. Common commands:

```sh
# Inspect and manage local state
idfon status
idfon identity list
idfon identity create work
idfon peer list
idfon peer add <endpoint-id-or-address> --name bob

# Store data and retrieve it by ticket
idfon put --file recording.wav > ticket.txt
idfon get "$(cat ticket.txt)" --out copy.wav

# Send text or a signaled file to a peer
idfon send bob --text "hello"
idfon send bob --file notes.pdf
idfon recv --out notes.pdf

# Publish or receive live audio
idfon send --stream --file audio.wav --loop > live-ticket.txt
idfon get "$(cat live-ticket.txt)" --out capture.wav

# A session-scoped 1:1 stream
idfon send bob --stream --file audio.wav
idfon recv --stream --out reply.wav
```

`put` stores data and prints a `BlobTicket`. `get` fetches a blob ticket to
stdout or a file. The CLI chunks transfers and the daemon stores them. The
data does not go through the chat message path.

`send PEER --file` stores a blob and sends its ticket as a peer message.
`recv` waits for that message, then fetches the blob. Text and file delivery
require the relevant local capability grants. See
[CLI data transfer](docs/cli-data.md) for pairing and transfer details.

`send --stream` without a peer publishes live audio and prints an
`iroh-live:` ticket. With a peer it opens a session-scoped 1:1 stream instead.
`recv --stream` accepts that stream. The CLI supports file sources. The native
clients provide microphone capture, not this command. Use
`send --stream --video` for video broadcasts. See
[video media](docs/video-media.md).

Useful operational commands:

```sh
idfon events --follow
idfon wait --type message.received --timeout-ms 60000
idfon operation get <operation-id>
idfon access check --subject <peer-id> --capability message.receive
idfon mcp listen --to <peer>
idfon shutdown
```

Use `--json` for response envelopes intended for scripts. `--socket`,
`--identity`, and `--keep-alive` are global options.

## MCP transport

Idfon includes an MCP transport bridge. It carries MCP stdio traffic over the
`idfon/mcp/1` iroh protocol. It does not implement MCP semantics.

```sh
# On the MCP-server side
idfon-mcp serve --command '<local-mcp-server>'

# On the client side
idfon-mcp connect --peer '<peer-ticket>'
```

`idfon-mcp --help` shows the exact bridge options. The daemon also has
`idfon mcp listen` and `idfon mcp configure` commands for daemon-backed
connections. `idfon-mcp-server` exposes selected idfon operations as MCP
tools. This area is experimental. See
[MCP transport](docs/mcp-transport.md).

## Native clients

The repository contains native clients for macOS and iOS. They use the same
daemon protocol and share the Rust networking/media components, but are not
release products yet.

Install the JavaScript workspace dependencies first:

```sh
pnpm install
```

Build and start the iOS app on a connected, unlocked iPhone:

```sh
pnpm ios build
DEVICE=<iphone-udid-or-name> pnpm ios device
```

`pnpm ios build` produces a device Release build. `pnpm ios device` installs
and starts it through `devicectl`. Omit `DEVICE` to use the first available
physical iPhone. The iOS app is device-only. The simulator is not supported.

Build and start the macOS app:

```sh
pnpm mac build
pnpm mac start
```

The macOS and iOS apps use the local daemon and share the Rust networking/media
components. See the platform-specific docs for details:

- [macOS client](mac/README.md)
- [Native SDK client](native/README.md)
- iOS client (`ios/`)

## Eve extension and agents

Build the `eve-idfon` extension and the agents under `agents/` separately from
the native clients. `pnpm eve` builds the extension first, then every
installed agent:

```sh
pnpm eve build      # eve-idfon + all agents
pnpm eve clean      # remove dist/.output everywhere
```

Use `pnpm agent` to manage individual agents:

```sh
pnpm agent build <name|all>     # eve build in agents/<name>
pnpm agent clean <name|all>
pnpm agent start <name>         # needs scripts/<name>-serve.sh
pnpm agent restart <name>       # stop then start
pnpm agent stop <name>
```

The agents under `agents/` are:

| Agent | Served | What it is |
| --- | --- | --- |
| `live-voice` | yes | GPT-Live full-duplex voice agent (audio/video calls, artifacts) |
| `llm` | yes | text-only agent reached by voice. The model is per-instance, so one agent can back several contacts |
| `agency` | yes | go-between. It introduces registered agents (A2A card relay) and signs nothing |
| `chat-echo` | no | deterministic echo mock used by the e2e scripts and `eve-spike` |

See [live-voice agent](docs/live-voice.md),
[voice side channel](docs/voice-side-channel.md) (the `llm` agent and
multi-contact model selection), [agent agency](docs/agent-agency.md),
and [Eve ingress channel](docs/idfon-eve.md).

## Privacy

Idfon is peer-to-peer: content moves directly between the parties' devices,
and keys live on the devices. The always-on edge is a **wake channel, not a
content host**. The precise picture, because vague privacy claims are worse
than none:

| Who | What they see |
|---|---|
| The other party(ies) | Messages and media, end-to-end over iroh (QUIC). A relay (N0's or `relay.idfon.net`) may forward **ciphertext** when NAT demands it. |
| The edge (`idfon.net` or self-hosted) | Push device tokens + topics per identity (needed to wake a phone), and — briefly — the **call invite** so a push-woken phone can pull it (in memory, ~5 min, dropped on cancel). The invite carries the call's media ticket; anyone who could read the edge store in those minutes could join that call's media. Self-host the edge if that is a concern for you. |
| Apple (APNs) | **Identifiers only** — `call_uuid`, `caller_id`, `has_video`. No names, no content; display names resolve on-device from the user's own contacts. |
| The iOS system call log | Real peer display names, by deliberate decision (donpark/idfon#48): the call log is the user's own device log. A “hide from call log” preference is the switch if that ever changes. |
| A diagnostics monitor (`IDFON-DIAG/1`) | Event markers only — wake outcomes, push registration results, timings, build stamps. Sent **only** to a monitor peer the user configures; no audio, no message content, no token values. |
| An MCP agent (see `docs/mcp-control.md`) | Reachable only over iroh, to parties the user approves: own devices (standing grants), approved parties (request-time approval block, short-lived scoped tickets), outsiders (one-shot tickets). Diagnostics are read-only first; every request and approval is audited; there is no public HTTP control endpoint. |

Two honest notes: capability **tickets are bearer credentials** — whoever
holds one can exercise its scoped rights until it expires, so treat them
like passwords. And while the iPhone app is suspended and the screen is
locked, nothing runs to be observed — the frozen window is visible only in
what the app reported before and after it.

## Documentation

Start at [docs/README.md](docs/README.md). It is the index of current docs by
topic.

## Development

```sh
cargo test -p idfon-protocol -p idfon-core -p idfon-daemon
scripts/test-cli.sh
scripts/test-e2e.sh
scripts/stream-e2e.sh
```

The workspace has the protocol, core networking, daemon, client, CLI, media,
and MCP crates. See the architecture documentation for the current boundaries
and known limitations.

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
