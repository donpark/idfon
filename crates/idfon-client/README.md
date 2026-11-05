# crates/idfon-client

The daemon IPC client: 4-byte big-endian length-prefixed JSON frames over a Unix
socket, one or more request/response exchanges per connection. This is the
**single source of truth** for client-side framing, socket-path resolution,
connect-retry policy, and response validation — matching the daemon's own
`read_frame`/`write_frame` loop.

- **Kind:** library
- **Consumers:** the `idfon` CLI and the c-FFI wrapper (`crates/iroh-c-ffi`),
  which is how the native/web-content shell reaches the daemon
- **Read more:** `docs/protocol.md`, `docs/daemon.md`

```sh
cargo test -p idfon-client
```
