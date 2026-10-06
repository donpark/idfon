# Build map: what to rebuild after a change

This repo is one Cargo workspace plus a vendored, workspace-excluded
`iroh-c-ffi` crate. Several projects consume the shared Rust core (the CLI, the
daemon, the three apps, the eve agents). Each consumes it through its own
entrypoint, and cargo/SwiftPM/Xcode cache per target dir — so a change only
needs the subprojects that actually link it. **When you change something shared,
say which subprojects must be rebuilt.**

## The two Rust target dirs

| Dir | Holds | Built by |
| --- | --- | --- |
| `target/` | the workspace (`crates/*`) | `cargo build`/`cargo test` at the repo root |
| `native/vendor/iroh-c-ffi/target/` | the vendored c-ffi crate (excluded from the workspace) | `cargo build --manifest-path native/vendor/iroh-c-ffi/Cargo.toml` |

The vendored crate produces `libiroh_c_ffi.{dylib,so}` (macOS/Linux) or
`.a` (iOS).

**Hard ordering:** the vendored c-ffi artifact for a target must exist *before*
`idfond` for that target — `crates/idfond/build.rs` links it. Every consumer
script already does this internally, so you rarely call cargo directly.

**One RUSTFLAGS value:** every vendored build uses
`RUSTFLAGS="-A unexpected_cfgs"`. A different value is a different cargo
fingerprint and recompiles the whole ~550-crate graph — see
`native/vendor/iroh-c-ffi/build.rs` for why the link args are not in RUSTFLAGS.

## Change → rebuild

| You changed | Rebuild |
| --- | --- |
| `crates/*` library logic | `cargo test -p <crate>`; add the consumer build below only if you need its artifact |
| `native/vendor/iroh-c-ffi/src/*` | the c-ffi artifact, then every consumer that links it: cli, mac, native, ios (staticlib) |
| `crates/idfond` (daemon) | `pnpm cli build`, `pnpm mac build`, `pnpm native build` (all bundle `idfond`) |
| `crates/idfon-cli` (CLI binary) | `pnpm cli build` |
| `ios/Idfon/*` (Swift) | `pnpm ios build` |
| `mac/Sources/*` (Swift) | `pnpm mac build` |
| `native/src/*`, `native/build.zig`, `native/app.json` | `pnpm native build` |
| `integrations/eve-idfon` or `agents/*` | `pnpm eve build` or `pnpm agent build <name>` |
| docs only | nothing |

Note: `idfond` is a workspace member whose `build.rs` links the vendored dylib,
so `cargo build --release` / `cargo test --workspace` at the root implicitly need
the vendored artifact first. Build it first if a bare workspace command fails
with `vendored dylib ... missing`.

## Consumer entrypoints

| Command | Entry | Produces |
| --- | --- | --- |
| `pnpm cli build [TARGET]` | `scripts/build-cli.sh` | dylib + `idfond` + `idfon` → `cli/<platform>/bin/` |
| `pnpm mac build` | `mac/build.sh` → `mac/build-deps.sh` + `swift build` | `mac/build/Idfon.app` |
| `pnpm native build` | `native/build-mac.sh` → `zig build` | `native/zig-out/bin/Idfon` + `Idfon.app` |
| `pnpm ios build` | `ios/build.sh` → `ios/build-deps.sh` + `xcodebuild` | device `.app` in `ios/.derived/` (device only, no simulator) |
| `pnpm eve build` | `scripts/eve.sh` | eve extension + every installed agent |
| `pnpm agent build <name>` | `scripts/agent.sh` | one agent |
| `pnpm all build` | every `@idfon/*` package | all of the host-buildable above |

Typical call sites pass `[TARGET]` for cross builds (e.g.
`scripts/build-cli.sh aarch64-apple-darwin`); cross targets need the toolchains
noted in the script headers.
