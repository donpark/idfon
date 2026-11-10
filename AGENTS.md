# Agent notes

## Documentation

Start at **`docs/README.md`** (the index) and read only the entries relevant to
the task. Do not bulk-read `docs/` — it is indexed so you don't have to. If you
add or materially change a doc, update the index.

## Layout

- `crates/` — Rust workspace (protocol, core, daemon, cli, gateway, h3, mcp, media, …).
- `crates/iroh-c-ffi` — the FFI crate behind `libiroh_c_ffi.dylib` (workspace member; its artifact must be built before `idfond`).
- `ios/Idfon`, `mac/Sources/Idfon` — the two native apps (duplicated UI code).
- `agents/`, `integrations/` — Eve agents and the eve-idfon bridge.

## Checks

- **Verify before retrying.** For network, device, or model checks, keep the returned operation ID and inspect that operation and its events before sending again. Reusing an idempotency key returns the existing operation; it does not re-run it. A new key creates a new request and may create another model turn.
- **MAST repeat/contradiction warning.** Stop and reconcile the latest tool result with the current process/config state before taking another action. Do not repeat the last command; state what evidence changed or switch to a read-only check.
- **One iPhone, several threads.** Install and launch through `ios/device.sh`,
  or wrap any `devicectl` command with `scripts/device-lock.sh <cmd>`. Both take
  one machine-wide lock (`/tmp/idfon-iphone.lock`), so two threads cannot
  interleave installs — which otherwise either fails with an SBMainWorkspace
  denial or silently puts the other thread's build under test.

- Rebuild scope: `docs/build.md` maps a change to the subprojects that must be
  rebuilt. When you change something shared, say which subprojects to rebuild.
- **Debugging calls/wakes/push: ask, don't grep.** Before any device-log
  archaeology (`devicectl` pulls, sysdiagnose, timestamp reconstruction), query
  the diagnostics the apps already report: `wake.trace` (one call's timeline:
  registration → ring → push → report → answer → media) and `diag.tail` via
  `idfon-mcp`; raw views at `<data-dir>/diag/`; edge health at `/_push/health`.
  See `docs/mcp-control.md` + `docs/diag.md`. (2026-11-10: hours were lost
  reconstructing from USB logs what the app was already reporting.)
- Rust: `cargo test -p <crate>` and `cargo check --workspace --all-targets`.
- macOS app: `swift build` in `mac/`.
- iOS: source files can be syntax-checked with `swiftc -parse <file>`; a full
  build needs the Xcode project and a physical iPhone (device-only, no simulator).
- Native shells use the `native-sdk` skill (vendored, installer-managed — do not
  edit it) plus the project-local `native-sdk-idfon` addendum holding our
  hard-won rules; iroh work uses the `iroh-protocols` skill (see
  `.agents/skills/` — shared by all harnesses; no per-harness skill folders).
  The vendored `native-sdk` is per-machine, not committed: install it with
  `npx skills add vercel-labs/native`.