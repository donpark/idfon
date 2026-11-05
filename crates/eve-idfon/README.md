# crates/eve-idfon

A generic idfon ingress-channel endpoint holder for Eve agents, with no
agent-specific behaviour: it holds the peer identity and serves the channel; the
agent decides what to do with what arrives.

Live-call handling is a **capability-keyed handler seam** (`eve_idfon::live`).
This binary registers none, so `IDFON-LIVE/1` controls fall through to the agent
as ordinary text. Builds that want live calls compose the platform `run()` with
a handler — see `crates/idfon-voice-agent`.

- **Kind:** binary (`eve-idfon`)
- **Read more:** `docs/idfon-eve.md`

```sh
cargo test -p eve-idfon
```
