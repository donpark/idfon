# npm distribution

How the `idfon` CLI ships through npm so `npx idfon` works with no install
decision and no Rust toolchain on the user's machine. Modeled on esbuild/turbo:
one main package wrapping per-platform packages that contain prebuilt binaries.

## Layout

```
npm/
├─ idfon/                      main package, unscoped name `idfon` (the npx entry)
│  ├─ bin/idfon.js             ~60-line launcher: platform map → resolve → spawn
│  └─ package.json             optionalDependencies pin exact versions of the 4 pkgs below
├─ idfon-darwin-arm64/         platform packages: os/cpu fields gate what npm installs;
├─ idfon-darwin-x64/           each ships bin/ = idfon + idfond + libiroh_c_ffi.{dylib,so}
├─ idfon-linux-x64/
└─ idfon-linux-arm64/
```

All packages are unscoped (no npm org needed). Platform-package binaries are
gitignored; they are built by `scripts/build-npm.sh` into the right package
before packing. The launcher resolves the platform package from `node_modules`
when installed, with a repo-layout fallback (`npm/idfon-<os>-<arch>`) for
running straight from a checkout.

The CLI (`idfon`) is a thin client over the `idfond` daemon's Unix socket;
both ship in the same package so the CLI's auto-spawn (it looks for `idfond`
next to its own binary) just works. The daemon links the vendored
`libiroh_c_ffi` dylib, which rides along via `@executable_path` (macOS) or
`$ORIGIN` rpath (Linux).

## Building

```sh
pnpm run build:npm                              # host target
scripts/build-npm.sh x86_64-apple-darwin        # Intel Mac — native SDK cross, no extra tools
scripts/build-npm.sh x86_64-unknown-linux-gnu   # linux cross: needs a Linux sysroot (see below)
scripts/build-npm.sh aarch64-unknown-linux-gnu
```

Platform notes:

- **macOS**: x86_64 dylibs autolink the Swift runtime via `@rpath`; the build
  adds `-Wl,-rpath,/usr/lib/swift` so dyld resolves it from the shared cache.
  Everything is ad-hoc signed by the build.
- **Linux**: `iroh-live` capture → `cpal` → PipeWire/ALSA native C libs, linked
  via pkg-config. Zig/zigbuild is only the linker — the headers must exist, so
  Linux targets build on native Linux machines (CI installs `libasound2-dev
  libpipewire-0.3-dev pkg-config`). Cross from macOS is not viable without a
  container/sysroot. Runtime ceiling: headless servers without the pipewire
  runtime libs fail the daemon at exec; desktop Linux is fine.
- **Windows**: not supported — IPC is a Unix socket (`std::os::unix`).
  Requires a named-pipe transport in `idfon-client` first.

## Verifying locally

```sh
node npm/idfon/bin/idfon.js --version    # exercises shim → binary resolution
node npm/idfon/bin/idfon.js status       # daemon auto-spawn with dylib
node npm/idfon/bin/idfon.js shutdown
npm pack                                  # per package; check tarball contents/exec bits
```

## Publishing

All five packages publish together — the main package's `optionalDependencies`
pin exact versions, so a partial publish breaks installs on platforms whose
package is missing (optional deps that fail to resolve are silently skipped,
and the launcher then errors at first command).

- **CI** (default): push tag `npm-v*` → `.github/workflows/npm.yml` builds all
  four targets on native runners, smoke-tests, packs, and publishes all five.
  Requires the `NPM_TOKEN` repo secret. Re-runs are idempotent via npm's
  duplicate-version rejection.
- **Local**: `npm login` once, then
  `npm publish` in `npm/idfon` and each `npm/idfon-*` dir.

Launch gate: the repo goes public first; `npm view idfon` confirmed the name
free (2026-09-06). Platform packages use the same 0.2.0 version as the Cargo
workspace — bump in lockstep.
