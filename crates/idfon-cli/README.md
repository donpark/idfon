# crates/idfon-cli

The `idfon` CLI: a thin client over the daemon's Unix socket. clap noun-verb
subcommands (`idfon peer add`, `idfon live stop`, …) map one-to-one onto daemon
methods (`peer.add`, `media.live.stop`, …). No state, no logic of its own.

Output shapes are contracts — scripts depend on them: `--json` prints the full
`Response` envelope; `put`/`stream`/`send-data` print a bare ticket;
`get`/`listen` stream bytes; bare `wait` prints one JSON line per event.

- **Kind:** binary (`idfon`)
- **Read more:** `docs/cli-architecture.md`, `docs/cli-data.md`,
  `docs/protocol.md`

```sh
cargo test -p idfon-cli
```
