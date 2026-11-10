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
- `bench-results/`, `dist/` — symlinks to the shared generated-artifact store at
  `~/.idfon/{bench-results,dist}` (multi-GB model-testing/training outputs, one
  copy for all worktrees). Fresh worktree: run `scripts/link-artifacts.sh`.

## iOS shipping (TestFlight)

- Read `docs/testflight-plan.md` before shipping. Use **`pnpm ios ship`**
  (`ios/upload.sh`): bump build number → build dependencies → Release archive →
  App Store Connect export → gate the exported IPA → upload. Bundle ID:
  `com.idfon.ios`; team: `RV27HPQNMF`. Xcode must have signing access for this team.
- **Ship only `ios/build/export/Idfon.ipa` after its gates pass.**
  `pnpm ios archive` runs the same export + gates without uploading; despite
  its name, its shipping output is an IPA, not the raw `.xcarchive`.
  Do not bypass this pipeline with an Organizer upload or an unchecked IPA.
- Automatic signing can development-sign the raw archive; export re-signs it
  for distribution. That is not a failure. Do not change the source
  `aps-environment` value or pin an Xcode-managed profile in manual mode to
  try to make the archive production-signed. Check the **final IPA**, not
  the source `.entitlements` file or archive, for shipping correctness.
- Before upload, require `aps-environment=production` in **both** the app's
  code-signature entitlements (`codesign -d --entitlements - --xml`) and its
  embedded profile (`security cms -D -i …/embedded.mobileprovision`), and
  `get-task-allow` absent or false. Verify bundle/team identity. Never bypass
  the script's gates for these entitlements, test-rig residue, or bundled
  APNs `.p8` keys. Apple documents checking both signature and profile in
  [QA1798](https://developer.apple.com/library/archive/qa/qa1798/_index.html).
- Upload uses `altool` when `APPLE_ID` + `APPLE_APP_SPECIFIC_PASSWORD` are set;
  otherwise the script stops with the gated IPA for Transporter. Obtain missing
  credentials through secure secret input; never commit or print them.
  **A successful export is not a successful upload.**
- Every script run bumps `CURRENT_PROJECT_VERSION` in
  `ios/Idfon.xcodeproj/project.pbxproj`; include that bump with the changes
  being shipped. Do not run shipping jobs concurrently in the same checkout.
  If upload status is uncertain, inspect that build in App Store Connect
  before retrying; do not blindly create another build.
- Report version/build, IPA path, gate results, and upload/processing status
  separately. Confirm processing and TestFlight availability in App Store
  Connect; surface compliance/review blockers rather than guessing answers.
  After installing from TestFlight, smoke-test a production VoIP push with the
  phone locked. PushKit uses the signed `aps-environment`: sandbox tokens sent
  to production APNs fail with `400 BadDeviceToken`, with no rejection callback
  to the app. Do not claim ringing works until that test passes.

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
- **Privacy posture lives in `README.md` ("Privacy").** Keep any new surface
  consistent with it: content end-to-end between the parties, the edge holds
  wake tokens + brief invites only, APNs payloads are identifiers-only,
  diagnostics are markers to a user-configured monitor, and control surfaces
  are tier-approved over iroh. If a change would add a new party to the table,
  update that table first.
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