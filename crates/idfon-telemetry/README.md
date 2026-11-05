# crates/idfon-telemetry

One process-wide tracing subscriber, shared by every idfon entry point: call
`init`/`init_file` and get the same logging everywhere. First call wins and
later calls are no-ops, so an embedding app can install the file sink before
starting the daemon.

Filter precedence, first set wins: `IDFON_LOG`, `RUST_LOG`, `IROH_C_LOG`, then
the caller's default.

- **Kind:** library
- **Read more:** `docs/observability.md`

```sh
cargo test -p idfon-telemetry
```
