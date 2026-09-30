# Agent notes

## Documentation

Start at **`docs/README.md`** (the index) and read only the entries relevant to
the task. Do not bulk-read `docs/` — it is indexed so you don't have to.
`docs/archive/` is historical design lineage; skip it unless you are
reconstructing why something is the way it is. If you add or materially change a
doc, update the index.

## Layout

- `crates/` — Rust workspace (protocol, core, daemon, cli, gateway, h3, mcp, media, …).
- `native/vendor/iroh-c-ffi` — the FFI crate behind `libiroh_c_ffi.dylib`; excluded from the workspace, built separately.
- `ios/Idfon`, `mac/Sources/Idfon` — the two native apps (duplicated UI code).
- `agents/`, `integrations/` — Eve agents and the eve-idfon bridge.

## Checks

- Rust: `cargo test -p <crate>` and `cargo check --workspace --all-targets`.
- macOS app: `swift build` in `mac/`.
- iOS: source files can be syntax-checked with `swiftc -parse <file>`; a full
  build needs the project/simulator.
- Native shells use the `native-sdk` skill; iroh work uses the `iroh-protocols`
  skill (see `.pi/skills/`).