# crates/idfond

The `idfond` launcher, and nothing else: parse arguments, then call
`idfon_daemon_run` in `libiroh_c_ffi.dylib`. All daemon behaviour lives in
`crates/idfon-daemon`; this binary exists so there is a process to start.

Build ordering matters: `build.rs` links the **release** c-FFI artifact, so that
must exist before this crate builds (`docs/build.md`).

- **Kind:** binary
- **Read more:** `docs/daemon.md`, `docs/build.md`

```sh
cargo build -p idfond
```
