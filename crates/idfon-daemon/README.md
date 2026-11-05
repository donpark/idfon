# crates/idfon-daemon

The daemon's feature functions and request dispatch: the blob store, live
sessions, the MCP bridge, and relay auth live here. It runs as the `idfond`
process, but the process is a shell — the same functions are reachable
in-process through `libiroh_c_ffi` (`idfon_daemon_run`), so an app embedding the
core does not talk to a socket.

- **Kind:** library
- **Modules:** `blob`, `live`, `mcp`, `relay_auth`
- **Read more:** `docs/daemon.md`, `docs/protocol.md`

```sh
cargo test -p idfon-daemon
```
