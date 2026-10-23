# Build map: what to rebuild after a change

This repo is one Cargo workspace — all of `crates/*`, including the C-FFI
crate `crates/iroh-c-ffi`. Several projects consume the shared Rust core (the
CLI, the daemon, the three apps, the eve agents). Each consumes it through its
own entrypoint, and cargo/SwiftPM/Xcode cache per target dir — so a change only
needs the subprojects that actually link it. **When you change something shared,
say which subprojects must be rebuilt.**

## The two Rust target dirs

| Dir | Holds | Built by |
| --- | --- | --- |
| `target/` | the whole workspace (`crates/*`, incl. `iroh-c-ffi`) | `cargo build`/`cargo test` at the repo root |
| `deploy/cloudflare/target/` | the Cloudflare Worker (standalone wasm workspace) | `deploy/cloudflare/build.sh` |

`crates/iroh-c-ffi` produces `libiroh_c_ffi.{dylib,so}` (macOS/Linux) or
`.a` (iOS).

**Hard ordering:** the c-ffi artifact for a target must exist *before*
`idfond` for that target — `crates/idfond/build.rs` links it. Every consumer
script already does this internally, so you rarely call cargo directly.

**No per-script RUSTFLAGS.** The dylib's install name/soname and idfond's
`$ORIGIN` rpath come from `build.rs` (`crates/iroh-c-ffi`, `crates/idfond`),
and `-A unexpected_cfgs` lives in the root `.cargo/config.toml`. A RUSTFLAGS
value set in a script overrides that config and is a different cargo
fingerprint — a full ~550-crate recompile. One exception:
`ios/build-deps.sh` sets it (byte-identically on both its cargo lines) for
the iOS link args.

## Change → rebuild

| You changed | Rebuild |
| --- | --- |
| `crates/*` library logic | `cargo test -p <crate>`; add the consumer build below only if you need its artifact |
| `crates/idfon-core` | the workspace, plus `deploy/cloudflare/build.sh` (the Worker uses only the wasm-gated security helpers). A change to `transport` (e.g. the `IDFON_RELAY_*` knob) also needs the c-FFI libs rebuilt — `ios/build-deps.sh` (device staticlib) and the `iroh-c-ffi` dylib, then `idfond` — or the apps won't pick it up. |
| `crates/idfon-daemon` (feature functions) | `cargo test -p idfon-daemon`, then the c-FFI libs rebuilt (`ios/build-deps.sh`, the `iroh-c-ffi` dylib, then `idfond`) — every app links the feature core through `libiroh_c_ffi`, whether it reaches it over the RPC socket or in-process (`idfon_request`). |
| `crates/idfon-director` (voice-agent harness) | `cargo test -p idfon-director`; the Apple staticlib is `cargo build -p idfon-director --features afm --target aarch64-apple-ios --release` (produces `libidfon_director.a`). `ios/build-deps.sh` builds and stages it into `ios/Vendor/device/`, and the Xcode project links it, so `pnpm ios build` covers it. `--features afm` links Apple Foundation Models via `fm-rs` and is Apple-only; the crate builds without it everywhere. It wraps `yoagent` (decision #31); the portable contract is `docs/voice-agent-loop-contract.md`. The mac app does **not** link it yet. |
| `deploy/cloudflare/*` | `deploy/cloudflare/build.sh`, then `wrangler dev`/`deploy` |
| `deploy/idfon-edge/Dockerfile` | rebuild/push the `idfon-edge` image (`edge-v*` tag or local build) |
| `deploy/digitalocean/*` | nothing to build; follows the image (runbook in its README) |
| `crates/iroh-c-ffi/src/*` | the c-ffi artifact, then every consumer that links it: cli, mac, native, ios (staticlib) |
| `crates/idfond` (daemon) | `pnpm cli build`, `pnpm mac build`, `pnpm native build` (all bundle `idfond`) |
| `crates/idfon-cli` (CLI binary) | `pnpm cli build` |
| `ios/Idfon/*` (Swift) | `pnpm ios build` |
| `mac/Sources/*` (Swift) | `pnpm mac build`, or `mac/Idfon.xcodeproj` (same sources; run-script phases build + embed the Rust deps) |
| `native/src/*`, `native/build.zig`, `native/app.json` | `pnpm native build` |
| `integrations/eve-idfon` or `agents/*` | `pnpm eve build` or `pnpm agent build <name>` |
| `crates/idfon-voice`, `crates/idfon-voice-agent` | `pnpm voice build` (dylib + the `eve-idfon-voice` holder + the `agents/voice` bundle) |
| docs only | nothing |

Note: `idfond` is a workspace member whose `build.rs` links the release c-FFI
dylib (even for debug builds), so `cargo build --release` /
`cargo test --workspace` at the root implicitly need
`cargo build --release -p iroh-c-ffi` first. Build it first if a bare workspace
command fails with `iroh-c-ffi dylib ... missing`.

## Build-time options

- `IDFON_TTS_PHONON=1` — compiles the Phonon 31m TTS engine into the apps
  (mac: selects the `ptts` package in `mac/Package.swift`, phonon builds raise
  the macOS floor to 15; iOS: `SWIFT_ACTIVE_COMPILATION_CONDITIONS=PHONON_TTS`
  in `ios/build.sh`, the `ptts` product is referenced either way and stripped
  when unused). Without it the engine is absent from the binary and the picker.
  Run `scripts/fetch-phonon-31m.sh` for the models. Details:
  `docs/voice-side-channel.md` ("TTS (build-time option)").

## Consumer entrypoints

| Command | Entry | Produces |
| --- | --- | --- |
| `pnpm build` | `scripts/build.sh` | everything host-side for the daemons/agents: voice stack → `idfond` + `idfon-cli` → `pnpm eve build` |
| `pnpm clean` | `scripts/build.sh clean` | every package's clean + agent bundles + the voice crates' cargo artifacts |
| `pnpm voice build` / `pnpm voice clean` | `scripts/voice.sh` | the voice stack alone: iroh dylib + `eve-idfon-voice` (signed) + `agents/voice` bundle |
| `pnpm cli build [TARGET]` | `scripts/build-cli.sh` | dylib + `idfond` + `idfon` → `cli/<platform>/bin/` |
| `pnpm mac build` | `mac/build.sh` → `mac/build-deps.sh` + `swift build` | `mac/build/Idfon.app` |
| `pnpm native build` | `native/build-mac.sh` → `zig build` | `native/zig-out/bin/Idfon` + `Idfon.app` |
| `pnpm ios build` | `ios/build.sh` → `ios/build-deps.sh` + `xcodebuild` | device `.app` in `ios/.derived/` (device only, no simulator) |
| `pnpm ios test` | `ios/test.sh` → `xcodebuild test` | runs `ios/IdfonTests` on a connected iPhone (Debug) |
| `pnpm eve build` | `scripts/eve.sh` | eve extension + every installed agent |
| `pnpm agent build <name>` | `scripts/agent.sh` | one agent |
| `pnpm all build` | every `@idfon/*` package | all of the host-buildable above |

Typical call sites pass `[TARGET]` for cross builds (e.g.
`scripts/build-cli.sh aarch64-apple-darwin`); cross targets need the toolchains
noted in the script headers.

## Build before `pnpm agent restart all`

`pnpm agent restart` stops an agent immediately (the serve script's `EXIT`
trap kills holder + bridge + eve), and the new serve script only starts serving
after its own rebuild of any Rust binary older than `crates/` — minutes when
you just changed code, and `pnpm agent restart all` returns long before
anything answers. Run `pnpm build` first so the guard is a no-op and each agent
is down for ~1–2 s. (`pnpm eve build` is not enough: it builds only the Eve
bundles, never `idfond`/`eve-idfon-voice`.)
