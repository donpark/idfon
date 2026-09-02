# Refactoring Plan: Shared Dynamic Library for Nufon

Status: proposed, 2026-09-02
Related discussion: app/daemon code duplication, bundle size analysis (27MB compressed).

## Summary

Two-stage migration to a shared Rust dynamic library:

- **Phase 1 (do now):** add a client-request C API to the existing `iroh-c-ffi`
  cdylib and switch the GUI app from statically linking `libiroh_c_ffi.a` to
  dynamically linking `libiroh_c_ffi.dylib`. Kills the Zig/Rust protocol
  duplication, exercises all dylib packaging problems while the daemon is
  untouched. Bundle size roughly unchanged (~27 → ~29MB compressed).
- **Phase 2 (gated on a real size requirement):** move the daemon's Rust stack
  onto the same dylib so it is shipped once instead of twice.
  ~27 → ~17MB compressed (~40% cut).

One artifact, two phases. No second, smaller dylib is created at any point.

## Baseline (measured 2026-09-02)

| Artifact | Uncompressed | gzip -9 |
|---|---|---|
| `Nufon.app/Contents/MacOS/Nufon` | 46MB | 15.2MB |
| `Nufon.app/Contents/MacOS/nufond` | 37MB | 13.2MB |
| `vendor/iroh-c-ffi/target/release/libiroh_c_ffi.dylib` (already built) | 38MB | 13.5MB |

Both binaries statically compile the same Rust stack (iroh 1.0, iroh-blobs
0.103, tokio, opus/cpal): ~40MB of Nufon's 46MB and nearly all of nufond's
37MB. The duplicated client-side protocol logic in Zig
(`native/src/iroh_ffi.zig`: `connectDaemon`, framing, retry loop, profile
paths, `"ok":false` sniffing) is ~100–120 lines and is the correctness
motivation; the double-shipped Rust stack is the size motivation.

Division of labor that must be preserved (verified in source):

- **GUI process:** audio capture/playback (`media_audio_*`, `media_recording_*`,
  `media_live_*` in `iroh-c-ffi/src/media.rs`). Stays in-process: macOS
  mic/camera permission is granted per app bundle, and low-latency device I/O
  belongs with the UI. `media.*` host calls bypass the daemon socket today and
  must keep doing so.
- **Daemon:** protocol layer, session/resource bookkeeping
  (`nufon-media::MediaService`, `media.session.*` / `media.resource.*`), blob
  storage, agentics.

The dylib changes where code lives, never who does what.

---

## Phase 1 — Client cdylib (app links the dylib)

Goal: `nufond.request` framing/paths/retry/error-mapping exist only in Rust;
app bundle carries `libiroh_c_ffi.dylib` instead of statically linking the
`.a`; daemon untouched.

### 1.1 Extend `iroh-c-ffi` with the client API

File: `native/vendor/iroh-c-ffi/src/lib.rs` (new `client.rs` module).

Add a path dependency on the protocol crate so framing types have one source
of truth:

```toml
# native/vendor/iroh-c-ffi/Cargo.toml
[dependencies]
nufon-protocol = { path = "../../../crates/nufon-protocol" }
```

(`nufon-protocol` pulls only serde/serde_json/thiserror — negligible dylib
growth. The vendored crate is excluded from the workspace; the path dep is
fine, but regenerate its `Cargo.lock` and commit it.)

New C ABI, three functions (implemented in `src/client.rs`, declarations in
`nufon_client.h` — a separate hand-maintained header, since plain
`#[no_mangle]` exports are not picked up by safer-ffi's generated
`irohnet.h`):

```c
// Resolve the socket path for a profile. Returns bytes written, or -1 on
// invalid profile/buffer. Mirrors the Zig logic exactly (NULL/empty profile
// reads NUFON_PROFILE, "default"/empty fallback, [A-Za-z0-9_-] validation,
// truncate-then-validate at 64 chars).
int32_t nufon_client_socket_path(const char* profile, char* out, size_t cap);

// Connect (timeout_ms = 0: single attempt; > 0: poll every 100ms until the
// deadline), write a length-prefixed request, read the response. Callee
// allocates the response; caller frees with nufon_client_result_free.
// Returns 0 on success, negative codes on failure (NUFON_ECONNECT,
// NUFON_EWRITE, NUFON_EREAD, NUFON_ETOOLARGE, NUFON_EINVALID, ...).
// Response JSON is deserialized with serde (nufon_protocol::Response) before
// being handed back, so malformed responses are rejected here, not sniffed;
// `ok` receives Response.ok (1/0) when non-null.
int32_t nufon_client_request(const char* socket_path,
                             const uint8_t* req, size_t req_len,
                             uint8_t** out, size_t* out_len,
                             uint8_t* ok,
                             uint32_t connect_timeout_ms);

void nufon_client_result_free(uint8_t* ptr, size_t len);
```

Decisions baked in (from discussion):
- **Callee-allocated result + free fn**, not a caller buffer: removes the
  8KB `max_result` ceiling permanently instead of preserving it. Cost is one
  extra function; the ownership rule is "free what request returned".
- **Daemon launch stays in Zig** (`launchDaemon` fork/exec is natural there,
  awkward in Rust). Contract: if `nufon_client_request` returns
  `NUFON_ECONNECT`, Zig calls `launchDaemon()` and calls request again with a
  5000ms connect window. The first call uses `connect_timeout_ms = 0` (single
  fast attempt, matching today's timing); the 100ms poll cadence lives in
  Rust. Zig never loops on connect.
- Thread safety: request is fully self-contained (connect → write → read →
  disconnect), matching today's per-job socket; document that it may be called
  concurrently from multiple worker threads.

Use plain `#[no_mangle] pub extern "C"` exports (boring, exact C types, no
header-generation coupling); raw pointers + `usize` throughout, ownership
rule is "free what request returned".

**As-built 2026-09-02:** done — `src/client.rs` (14 tests, all passing),
`nufon_client.h`, `nufon-protocol` path dep added to the vendored crate.
During end-to-end verification a previously undocumented wire feature
turned up: the three `*.compact` methods (`peers.compact`,
`identities.compact`, `events.compact`) return **raw binary frames**, not
JSON Responses (the old Zig host tolerated them via the `"ok":false`
substring sniff). The client passes them through verbatim with `ok = 1`
(`BINARY_RESPONSE_METHODS` in `client.rs`); documented in `nufon_client.h`.
Note: `scripts/test-rust.sh` now runs the vendored crate's client tests
alongside the workspace suite.

### 1.2 Slim down `iroh_ffi.zig`

File: `native/src/iroh_ffi.zig`

**As-built 2026-09-02:** done. `daemonWorker` now calls `nufon_client_request`
(fast attempt → `launchDaemon` on `NUFON_ECONNECT` → 5000ms-window retry);
`daemonError()` maps codes to the historical strings; `profilePaths` gets the
socket path from `nufon_client_socket_path` (data dir still computed in Zig
with a `ponytail:` comment); `connectDaemon`, the Zig framing, the retry
loop, `profilePathsDefault`, and the `"ok":false` sniffing are deleted.
Verified: `zig build` + `zig build test` clean; C harness round-trips a real
`nufond` (status → ok=1, unknown method → ok=0 + error body).

**Ceiling note:** the completion queue (`Completion.bytes`, 16 × 8 KiB
fixed buffers) still caps delivered responses at 8 KiB — the 1 MiB frame
limit is accepted by the client but larger responses fail with
`daemon_result_too_large` exactly as before. Lifting it means heap-allocating
completions; deferred (ponytail comment in `daemonWorker`).

### 1.3 Switch the link in `build.zig`

File: `native/build.zig`

**As-built 2026-09-02:** done. `RUSTFLAGS=-C link-arg=-Wl,-install_name,
@executable_path/libiroh_c_ffi.dylib` is set on the cargo step (install name
set at link time, no `install_name_tool` patching); exe + tests link the
dylib via `addObjectFile`; a `b.getInstallStep()` install step copies the
dylib to `zig-out/bin/`. `Nufon` is 46 MB → **7.9 MB**; `otool -L` shows
`@executable_path/libiroh_c_ffi.dylib`. Verified: dylib-absent launch fails
loudly with dyld "Library not loaded"; dylib-present run loads, serves host
requests, and the packaged + ad-hoc-signed bundle works end-to-end.

### 1.4 Bundle packaging & signing

The app is assembled via `native package --target macos --binary
zig-out/bin/Nufon --output Nufon.app` (see `native/README.md`); current
signing is `none` (`signing-plan.txt`).

**As-built 2026-09-02:** the packager does not carry the dylib, so the
`build` script (mirroring the existing `nufond` copy) appends
`cp zig-out/bin/libiroh_c_ffi.dylib 'Nufon.app/Contents/MacOS/'`. With
`--executable_path` install name no rpath changes are needed in the bundle.
When real signing/notarization lands, the dylib must be signed with the same
identity *before* the bundle is sealed and must be listed in the
notarization (added to `signing-plan.txt` below). Windows: no Windows
packaging exists yet; when it lands the DLL goes next to the exe. Do
nothing now.

### 1.5 Behavior parity checklist

The dylib swap must be invisible to the TS layer. Verify each:

- [ ] Same error strings reach `host.complete` for: daemon not running,
      daemon dies mid-request, oversized/invalid response, profile env var
      invalid.
- [ ] `nufon status` via the socket through the GUI host call path works with
      daemon cold-started (launchDaemon → connect retry path).
- [ ] `NUFON_PROFILE` routing: socket path, data dir, and `nufond` args all
      agree for `default`, a custom profile, and an invalid profile.
- [ ] Media commands still bypass the socket (capture, playback, live,
      devices).
- [ ] Concurrent requests (two UI actions at once) interleave correctly.
- [ ] App launches with the dylib **absent**: must fail with a clear load
      error, not a silent crash — confirms the dylib is actually being used,
      not a stale static link.

### 1.6 Checks

- Rust: unit tests in `iroh-c-ffi` for `nufon_client_socket_path` (profile
  validation table) and a loopback test spawning a stub socket server that
  speaks the 4-byte length-prefix framing and asserting
  `nufon_client_request` round-trips (happy path, short read, oversized
  response, bad JSON).
- Zig: the `artifacts.tests` build still links and passes.
- Manual: `scripts/test-rust.sh`, `scripts/test-media.sh`, then the parity
  checklist above.

### 1.7 Rollback

Revert `build.zig` to `addObjectFile(libiroh_c_ffi.a)` and restore the Zig
framing (keep the commit pair adjacent: one commit for the Rust client API,
one for the Zig/build swap). The `.a` continues to build unmodified.

### Phase 1 exit criteria

- `libiroh_c_ffi.a` no longer linked into `Nufon`; dylib in bundle and signed
  plan updated.
- `iroh_ffi.zig` no longer contains framing/socket-path/`"ok"`-sniffing code.
- Protocol changes (frame format, socket path scheme, response shape) require
  editing Rust only; grep confirms no Zig copies remain.
- Compressed bundle ≈ 28–30MB (accepted regression).

---

## Phase 2 — Daemon onto the shared dylib (gated)

**Status 2026-09-02: implemented** (Option A) on the branch, see as-built
below. Note the release-profile wins (Phase 1 follow-up) already brought the
bundle to ~11MB compressed, most of the way to the original ~17MB estimate;
Phase 2 removes the remaining daemon-stack copy.

Target state: `Contents/MacOS/` contains `Nufon` (thin), `nufond` (thin),
`libiroh_c_ffi.dylib` (the stack) → ~17MB compressed.

### 2.1 Choose the sharing mechanism

**Option A — daemon core moves into the cdylib (full dedup, recommended if
the gate trips).**

- Move `nufond`'s core (request handling in `main.rs`, `nufon-media::MediaService`
  wiring, blob store) behind a C-ABI surface: roughly
  `nufon_daemon_start(config)`, `nufon_daemon_stop()`, with the daemon's
  JSON-RPC-over-socket loop living in the dylib.
- `nufond` binary shrinks to argv parsing + `nufon_daemon_start` + signal
  handling.
- Cost: wrapping the daemon lifecycle in C ABI (tokio runtime ownership
  crosses the boundary once, at start/stop — manageable); all remaining
  daemon features must route through the C surface going forward.
- Payoff: complete dedup, `nufon-media`/`iroh-live` version skew impossible.

**Option B — Rust `dylib` crate-type shared within the workspace (partial
dedup, cheaper).**

- Add `crate-type = ["dylib"]` to a new `nufon-stack` facade crate; `nufond`
  and the cdylib both link it. Same rustc guaranteed (one workspace build).
- Payoff: no C-ABI rework for the daemon.
- Cost: monomorphized generics (tokio/iroh are generic-heavy) are still
  codegen'd into each binary — dedup is maybe half the theoretical win;
  brittle rpath/install-name handling for a benefit smaller than Option A.

Recommendation: **Option A**. If the gate trips, the extra week of C-ABI work
is cheap relative to re-doing the same packaging work twice.

### 2.2 Steps (Option A)

1. Extract `nufond/src/main.rs` (3,417 lines) into `crates/nufon-daemon-core`
   with a plain Rust API (`Daemon::start(config) -> Handle`); `nufond` main
   becomes a wrapper. No behavior change; ship and verify this alone.
2. Add the C-ABI lifecycle wrappers to `iroh-c-ffi`; nufond links the dylib
   and calls `nufon_daemon_start`. Media bookkeeping (`MediaService`) moves
   in with it; capture/playback (`media.rs`) stays GUI-entry-point-only.
3. Rebuild bundle; both thin binaries + one dylib. Verify the parity
   checklist again, plus: daemon log redirection (`/tmp/nufond-auto-*.log`)
   and `waitpid` auto-start behavior unchanged.
4. Re-measure sizes; expect ~17MB compressed. If Rust `dylib` dedup (Option
   B) was chosen instead, re-measure to confirm the win is worth the
   brittleness before deleting the static path.

### Phase 2 exit criteria

- Single copy of the Rust stack in the bundle; `nufond` < 2MB. ✓ (296KB)
- `nufon-media` and `iroh-c-ffi` cannot have divergent `iroh-live` versions. ✓ (one crate graph)
- Both processes share dylib pages in memory (verify with `vmmap`).

### Phase 2 as-built 2026-09-02

- **Step 0 (client-core extraction):** new workspace crate
  `crates/nufon-client` — pure-Rust IPC client (`Client`, `ClientResponse`,
  `socket_path_for`, retry, framing, `*.compact` binary pass-through), 11
  tests. `iroh-c-ffi/src/client.rs` is now a thin C-ABI adapter over it (4
  C-ABI tests); `crates/nufon-cli` uses the same core (its framing copy is
  gone).
- **Daemon core:** new workspace crate `crates/nufon-daemon` — the former
  `nufond/src/main.rs` + `blob.rs` with `DaemonConfig`, `run()`,
  `run_blocking()` (own tokio runtime, ctrl_c shutdown). 14 tests moved with
  it.
- **Thin daemon:** `nufond` binary is 296KB: arg parsing + `extern "C"
  nufon_daemon_run(socket, data_dir, transport)`; `build.rs` adds the dylib
  link-search/link-lib and copies the dylib next to the built binary so
  `@executable_path` resolves in `target/<profile>/`.
- **Dylib:** `iroh-c-ffi/src/daemon.rs` exports `nufon_daemon_run` (blocking,
  declared in `nufon_client.h`); dylib grew 16 → 18MB (daemon core moved in).
- **build.zig:** daemon cargo step depends on the dylib cargo step; the
  obsolete `/usr/lib/swift` rpath patch removed (dylib has no `@rpath` refs).
- **Bundle:** 18MB dylib + 7.9MB app + 312KB nufond ≈ **11MB compressed**
  (was ~27MB before Phase 1). Verified: thin nufond serves the CLI, SIGINT
  cleans the socket, `crates/nufond/tests/process.rs` passes, packaged +
  ad-hoc-signed bundle runs end-to-end.

---

## Follow-ups (found in the Phase 1 review, not urgent)

- `crates/nufon-cli` still carries its own copy of the framing
  (`connect` + length-prefix + read in `main.rs`). Rust-to-Rust duplication
  within one workspace (lower drift risk than the old Zig copy), but the
  clean endgame is extracting the client core (framing/paths/retry, no FFI)
  into a small workspace crate used by both the CLI and the vendored FFI
  wrapper — do it together with Phase 2, not before.
- The completion queue cap (8 KiB) is the only remaining response ceiling
  (see 1.2). Heap-allocating completions lifts it toward the 1 MiB frame
  limit.

## Also-rans (do regardless, cheap size wins before/without Phase 2)

- `[profile.release]` in both Cargo manifests: `panic = "abort"`, `lto =
  "fat"`, `strip = "symbols"`, `codegen-units = 1`. Often 10–20% off Rust
  binaries; zero risk. Measure before/after.
- Confirm the Zig app side is built `ReleaseFast` with stripped symbols in
  the packaged artifact (manifest says `ReleaseFast`; verify symbols are
  stripped in `zig-out/bin/Nufon`).

## Risks

| Risk | Mitigation |
|---|---|
| Dylib not found at load (bad install name/rpath) | `install_name_tool -id @rpath/...` in build; `otool -L` check in CI; parity item 1.5 (launch without dylib) |
| Notarization rejects unsigned nested dylib | Sign dylib before bundling; add to `signing-plan.txt` |
| Behavior drift in error strings/retry timing | Parity checklist 1.5; error-string mapping table kept in one Zig switch |
| ABI misuse (freed buffers, concurrent calls) | Only 3 functions; ownership rule documented at declaration; `nufon_client_result_free` pairs with request |
| `iroh-c-ffi` Cargo.lock churn from `nufon-protocol` path dep | Commit regenerated lock; pin serde versions to match workspace |
| Phase 2 scope creep into daemon rework | Hard gate: do not start without a size/skew requirement; Phase 1 is complete and shippable on its own |
