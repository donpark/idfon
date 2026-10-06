# Agent notes

## Documentation

Start at **`docs/README.md`** (the index) and read only the entries relevant to
the task. Do not bulk-read `docs/` — it is indexed so you don't have to. If you
add or materially change a doc, update the index.

## Layout

- `crates/` — Rust workspace (protocol, core, daemon, cli, gateway, h3, mcp, media, …).
- `native/vendor/iroh-c-ffi` — the FFI crate behind `libiroh_c_ffi.dylib`; excluded from the workspace, built separately.
- `ios/Idfon`, `mac/Sources/Idfon` — the two native apps (duplicated UI code).
- `agents/`, `integrations/` — Eve agents and the eve-idfon bridge.

## Checks

- Rebuild scope: `docs/build.md` maps a change to the subprojects that must be
  rebuilt. When you change something shared, say which subprojects to rebuild.
- Rust: `cargo test -p <crate>` and `cargo check --workspace --all-targets`.
- macOS app: `swift build` in `mac/`.
- iOS: source files can be syntax-checked with `swiftc -parse <file>`; a full
  build needs the Xcode project and a physical iPhone (device-only, no simulator).
- Native shells use the `native-sdk` skill; iroh work uses the `iroh-protocols`
  skill (see `.pi/skills/`).