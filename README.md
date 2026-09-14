# Idfon

Idfon is a peer-to-peer communication and data-transfer system built on
[iroh](https://www.iroh.computer). It provides a local daemon, a CLI, and
native clients. Identities and peer state are stored locally; connections may
use direct paths, discovery, or relays supplied by iroh.

> **Status:** experimental and pre-release. The CLI is available as an npm
> package. The native clients are still under development.

## CLI installation

The npm package includes prebuilt binaries for macOS (arm64, x64) and Linux
(x64, arm64). Node.js 18 or later is required by the launcher.

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
stdout or a file. Transfers are chunked by the CLI and stored by the daemon;
the data itself is not sent through the chat message path.

`send PEER --file` stores a blob, sends its ticket as a peer message, and
`recv` waits for that message before fetching the blob. Text and file delivery
require the relevant local capability grants. See
[CLI data transfer](docs/cli-data.md) for pairing and transfer details.

`send --stream` without a peer publishes live audio and prints an
`iroh-live:` ticket. With a peer it opens a session-scoped 1:1 stream instead;
`recv --stream` accepts that stream. File sources are supported by the CLI;
microphone capture is provided by the native clients, not this command. Video
broadcasts are available with `send --stream --video`; see
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
`idfon/mcp/1` iroh protocol; it does not implement MCP semantics.

```sh
# On the MCP-server side
idfon-mcp serve --command '<local-mcp-server>'

# On the client side
idfon-mcp connect --peer '<peer-ticket>'
```

The exact bridge options are shown by `idfon-mcp --help`. The daemon also has
`idfon mcp listen` and `idfon mcp configure` commands for daemon-backed
connections. `idfon-mcp-server` exposes selected idfon operations as MCP
tools. This area is experimental; see [MCP transport](docs/mcp-transport.md).

## Native clients

The repository contains native clients for macOS and iOS. They use the same
daemon protocol and share the Rust networking/media components, but are not
release products yet.

- [macOS client](mac/README.md)
- [Native SDK client](native/README.md)
- iOS client (`ios/`)

## Documentation

- [Communication model](docs/communication-model.md)
- [CLI data transfer and live streaming](docs/cli-data.md)
- [Audio media](docs/audio-media.md)
- [Video media](docs/video-media.md)
- [npm distribution](docs/npm-distribution.md)
- [MCP transport](docs/mcp-transport.md)
- [Architecture plan](docs/architecture-plan.md)
- [Troubleshooting](docs/troubleshooting.md)

## Development

```sh
cargo test -p idfon-protocol -p idfon-core -p idfon-daemon
scripts/test-cli.sh
scripts/test-e2e.sh
scripts/stream-e2e.sh
```

The workspace is organized around the protocol, core networking, daemon,
client, CLI, media, and MCP crates. See the architecture documentation for
the current boundaries and known limitations.

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
