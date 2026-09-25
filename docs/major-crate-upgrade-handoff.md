# Task: upgrade idfon's major-version dependencies

Repo: `/Users/don/dev/idfon` (Rust workspace + a vendored, workspace-excluded FFI crate).

## Context / current state (2026-09-16)
- Minor (semver-compatible) updates are already done: vendored `native/vendor/iroh-c-ffi` lock was bumped in `aece01e`, and `mac/Vendor/*.dylib` was untracked/gitignored in `bd6b582`. Tree is clean.
- The main workspace `Cargo.lock` is already at the newest semver-compatible versions. The iroh family is already latest: `iroh 1.2.0`, `iroh-blobs 0.103.0`, `iroh-gossip 0.101.0`, `iroh-tickets 1.0.0`, `iroh-relay 1.2.0`.
- Recent rename (commit `b58914b`): `idfon-eve` → `eve-idfon` everywhere (crate, binary, npm packages, env vars `EVE_IDFON_HOLDER` / `EVE_IDFON_KEY` / `EVE_IDFON_MODEL`). Doc filenames like `docs/idfon-eve.md` were intentionally left.

## Goal
Bump the remaining **major** versions, one dependency (or small group) at a time, fixing API fallout and verifying with builds/tests. Semver-compatible bumps first (see note), majors second.

## In scope — workspace direct deps (Cargo.toml)
| crate | current | target | declared in |
|---|---|---|---|
| `rusqlite` (bundled) | 0.32 | 0.40 | `crates/idfon-daemon/Cargo.toml` |
| `ed25519-dalek` | 2 | 3 | `crates/idfon-core/Cargo.toml`, `crates/eve-idfon/Cargo.toml`, `crates/idfon-daemon/Cargo.toml` |
| `rand_core` | 0.6 | 0.10 | `crates/idfon-core/Cargo.toml` (coupled to ed25519-dalek 3) |
| `base64` | 0.22 | 0.23 | `crates/eve-idfon/Cargo.toml` |
| `hang` | 0.19.5 | 0.20 | `crates/idfon-media/Cargo.toml` |

## In scope — vendored `native/vendor/iroh-c-ffi/Cargo.toml`
| crate | current | target |
|---|---|---|
| `jpeg-encoder` | 0.6 | 0.7 |
| `iroh-mdns-address-lookup` | 0.4.0 | 0.5.0 |

## Held / out of scope unless explicitly approved
- `moq-mux` 0.5.6 → 0.9.15 and `moq-net` (`moq-lite`) 0.1.18 → 0.2.21: the comment in `crates/idfon-media/Cargo.toml` says these **must stay in lock with what `iroh-live` resolves to**. They only move when the pinned `iroh-live` git rev moves.
- `iroh-live` is pinned: `rev = a130f15f06c3dea8a73fc87d76c729793b33ac97` in `crates/idfon-media` and `native/vendor/iroh-c-ffi`. Bumping it unlocks the moq bumps but also re-triggers the open watch item n0-computer/iroh-live#63 (`SharedVideoSource` `Ok(None)` hot-spin). Treat as a separate, explicitly-approved task.

## Note to verify first
`cargo update --dry-run --workspace` reported **0 locks** while still listing many "behind latest" entries (some are out-of-range majors like the table above, but some are in-range patches such as `quinn 0.11.11→0.11.12`, `rustls 0.23.44→0.23.45`, `redb 4.2→4.3`, `cc 1.4.5→1.4.6`). Re-run plain `cargo update` (no `--workspace`) in the repo root and confirm whether those patch bumps apply before assuming the workspace lock is fully current.

## Project conventions (must follow)
- Build product artifacts through the pnpm entrypoints, **not** raw cargo:
  - `pnpm cli build` → host `libiroh_c_ffi.dylib` + `idfond` + CLI, staged into `cli/idfon-darwin-arm64/bin/`
  - `pnpm mac build` → stages `mac/Vendor/libiroh_c_ffi.dylib`, builds SwiftPM `mac/build/Idfon.app`
  - `pnpm ios build` → rebuilds `ios/Vendor/device/libiroh_c_ffi.a`, device Release app
  - `pnpm native build` → Native-SDK/zig `Idfon.app` + dylib
- iOS is **device-only, never simulator**: use `pnpm ios build` and `pnpm ios device` (install + launch on Don's iPhone). Do not use `--sim`, `pnpm ios start`, or simulator destinations; `ios/Vendor/sim/` is irrelevant.
- Raw cargo is fine for the Rust iteration loop: `cargo check --workspace --all-targets`, `cargo test --workspace --all-targets`, and vendored checks/tests from `native/` via `cargo check --manifest-path vendor/iroh-c-ffi/Cargo.toml` and `cargo test --manifest-path vendor/iroh-c-ffi/Cargo.toml --lib`. Product artifacts still go through the pnpm entrypoints.
- Two lockfiles: the workspace `Cargo.lock` and `native/vendor/iroh-c-ffi/Cargo.lock` (the vendor crate is `exclude`d from the workspace).
- Commit after each dependency (or logical group). Version stays in lockstep at `0.5.0` (`[workspace.package]` + npm packages) — bump manually if needed.
- Generated artifacts are not repo content: `ios/Vendor/` is gitignored, `mac/Vendor/*.dylib` is now gitignored, `cli/idfon-*/bin/` is gitignored.

## Suggested sequence
1. Recon: plain `cargo update` in the workspace; `cargo update` in `native/vendor/iroh-c-ffi`; re-check latest via crates.io for the table crates.
2. Do semver patches from step 1 first, verify, commit.
3. One major at a time, easiest first:
   - `base64 0.22→0.23` (mechanical API tweaks; `crates/eve-idfon`)
   - `hang 0.19→0.20` (`crates/idfon-media`)
   - `jpeg-encoder 0.6→0.7` (vendored)
   - `iroh-mdns-address-lookup 0.4→0.5` (vendored)
   - `ed25519-dalek 2→3` + `rand_core 0.6→0.10` together (`crates/idfon-core`, `crates/eve-idfon`)
   - `rusqlite 0.32→0.40` last (`crates/idfon-daemon`; bundled SQLite, largest API drift)
4. After each: `cargo check --workspace --all-targets` → `cargo test -p idfon-protocol -p idfon-core -p idfon-daemon`.
5. After all Rust changes: rebuild native libs and apps via `pnpm cli build && pnpm mac build && pnpm ios build && pnpm native build`.
6. Install/verify on the physical iPhone with `pnpm ios device`.

## Implementation status (2026-09-16)

Completed in the current working tree:
- Workspace patch refresh via plain `cargo update` (32 compatible updates).
- `base64` 0.22 → 0.23.
- `ed25519-dalek` 2 → 3 and `rand_core` 0.6 → 0.10. `rand_core` 0.10 no longer provides `OsRng`; identity generation now uses `getrandom::SysRng` through `UnwrapErr`.
- `rusqlite` 0.32 → 0.40.
- `hang` 0.19 → 0.20.
- Vendored `jpeg-encoder` 0.6 → 0.7 and `iroh-mdns-address-lookup` 0.4 → 0.5.

Verification completed:
- `cargo check --workspace --all-targets` passed.
- Workspace tests passed for all crates except the `idfond` binary test process, which was SIGKILLed by the OS; a targeted retry reproduced the SIGKILL without a Rust failure. Other workspace tests passed, including `idfon-media`, `idfon-daemon`, `idfon-core`, and `eve-idfon`.
- `cd native && cargo check --manifest-path vendor/iroh-c-ffi/Cargo.toml` passed.
- `cd native && cargo test --manifest-path vendor/iroh-c-ffi/Cargo.toml --lib` passed (24 tests).

The direct `hang` upgrade intentionally leaves `hang 0.19.5`/`moq-net 0.1.18` in the lockfile for the pinned `iroh-live` graph while the direct path uses `hang 0.20.12`/`moq-net 0.2.21`. Both paths compile; do not bump `iroh-live` or `moq-mux` in this task.

## Gotchas
- After any relink, the macOS dylib needs an ad-hoc re-sign or the kernel SIGKILLs it at exec ("Code Signature Invalid"): the build scripts already run `codesign --force -s -`; keep that if you call cargo directly.
- Vendored-build rustflags matter: run from `native/` (or use the scripts) so `native/.cargo/config.toml` (`-A unexpected_cfgs`) and the `@executable_path/libiroh_c_ffi.dylib` install name are applied.
- `rusqlite` is `features = ["bundled"]`, so the SQLite C build is part of the compile; expect longer builds.
- Don't commit `mac/Vendor/*.dylib` or other generated libs.
