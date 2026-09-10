# Troubleshooting and known issues

Notes on real failure modes observed during testing, their root causes, and
the fixes. Kept so the same class of bug is easy to recognize next time.

## GUI sends rejected with `idempotency_key_conflict` (2026-08-30)

**Symptom.** Sending a chat message from one GUI instance to another was
silently not received. The GUI showed the message as failed (or nothing at
all); no `message.received` event ever appeared on the other side, and no new
operation was created in the daemon store.

**Diagnosis path.**

1. GUI trace logs (`/tmp/idfon-<pid>.log`, written by `native/src/iroh_ffi.zig`)
   showed the daemon's response to `message.send`:
   `{"ok":false,"error":{"code":"idempotency_key_conflict",...}}`.
2. The daemon store (`/tmp/idfon*/state.json`) contained operations from
   *previous* testing sessions with the same `(target, idempotency_key)` pair
   but a different request fingerprint.
3. The GUI (`native/src/core.ts`) built the idempotency key as
   `gui-${model.history.length}` — a value derived only from in-memory state
   that resets on every app restart. Every fresh session started keying sends
   `gui-0`, `gui-1`, ... again, colliding with operations persisted days
   earlier.

**Root cause.** The daemon deduplicates `message.send` on
`(target, idempotency_key)` and compares the request fingerprint when a pair
matches. That behavior is correct and intentional (safe retries, see
*Operations and retries* in the architecture plan). The bug was client-side:
the GUI reused keys across process restarts, so a brand-new message looked
like a replay of an old one and was rejected — or worse, would have been
answered with the *stale* operation's `delivered` status without being sent.

**Fix.** Send keys are now unique per message *and* per session:
`gui-${tickAt}-${history.length}`, where `tickAt` is the timestamp delivered
by the 1-second event-poll timer (`poll_events` msg). This survives restarts
and cannot collide across sessions. Note the Native SDK checker forbids
reading `Date.now()` inside `update` (updates must stay deterministic);
ambient time must arrive through the subscription tick instead.

**Lesson.** Idempotency keys derived from client-local state that resets
(history length, per-session counters) are not unique across restarts. Keys
must be unique per distinct send over the *daemon's* lifetime of stored
operations, not per GUI session.

**Testing note.** Testing two identities (Alice/Bob) on one computer is a
test-only setup: both app instances normally talk to the same default-profile
daemon unless each is launched with its own profile
(`native/run-profile.sh <name>` sets `IDFON_PROFILE`, giving each instance its
own socket and data directory under `/tmp/idfon-<name>/`). The bug above was
independent of that setup — it would bite identically between two machines —
but the shared-daemon setup made the stale operations from earlier sessions
visible in one `state.json`, which helped diagnosis.

## Related: stale daemon lock after a crash (2026-08-30)

A crashed daemon left `/tmp/idfon/state.lock` behind (its `Drop` never ran),
and every subsequent daemon start failed with
`data directory is already locked: ...`, which the GUI surfaced as
`daemon_unavailable`. Fixed in `DataLock::acquire`
(`crates/idfond/src/main.rs`): the lock file records the holder's PID, and a
new daemon now takes the lock over when that PID is dead. See the
`data_lock_recovers_stale_lock_from_dead_pid` test.

## Garbage text in the call-error banner (2026-09-09)

**Symptom.** Pressing the video-call button showed a banner of mojibake
(white tofu blocks with printable fragments like `al%R`) instead of the
failure reason. The banner length was correct; only the contents were garbage.

**Diagnosis path.**

1. GUI trace log (`/tmp/idfon-<pid>.log`) showed the sequence:
   `media.session.start` OK, then `media.live.video_start` completing
   `ok=false bytes=24` — 24 bytes matches the real error
   "input stream not running", so the failure text itself was fine.
2. That text comes from `media_live_last_error()` (Rust,
   `native/vendor/iroh-c-ffi/src/media.rs`), fetched by `last_live_error()`
   in `native/src/iroh_ffi.zig`.

**Root cause.** Use-after-free. `last_live_error()` had
`defer ffi.rust_free_string(err)` and returned the span **into** the caller,
which only then called `complete(...)` — the `defer` ran first, so
`complete()` copied freed heap memory. Correct length, garbage bytes.

**Fix.** `last_live_error()` now copies the string into a module-level buffer
before the `defer` frees it. Rule of thumb: an FFI helper that returns a
span into Rust-owned memory must not free that memory itself when the
consumer runs after the return.

## iOS camera capture migration: silent AVCaptureVideoDataOutput (2026-09-09, FIXED)

**Symptom.** After migrating iOS camera capture from vendored-nokhwa to Swift
AVCaptureSession (`ios/Idfon/CameraPusher.swift` -> `media_video_push_frame`
FFI -> `PushFrameSource` in `native/vendor/iroh-c-ffi/src/media.rs`), iPhone->
Mac video calls published audio but no video: the Swift session looked
healthy by every observable (running, connection active+enabled, TCC
authorized, no error/interruption notifications) yet `captureOutput` never
fired — not once, for fully vanilla rebuilt sessions, surviving a reboot.

**Root cause.** The session was started while the app was NOT active
(foregroundInactive=1, from `didFinishLaunching` on a `devicectl` launch).
iOS capture arbitration denies frame delivery to non-active clients: the
session reports `isRunning=true` with an active connection and NO error
notification — there was no state transition, the session was born
ineligible. Diagnostics that mislead: `scenes=[1]` is foregroundInactive
(UISceneActivationState.foregroundActive = 0), and read-back
`PixelFormatType 1111970369` is `'BGRA'`, not `'420f'`. A session denied this
way never recovers; rebuilding on the same AVCaptureSession object keeps the
state.

**Fix (CameraPusher.swift).** `start()` checks `UIApplication.shared
.applicationState`; when inactive it defers to
`UIApplication.didBecomeActiveNotification`. The rebuild ladder constructs a
FRESH `AVCaptureSession` per attempt. `start()` logs `applicationState` at
request and at `startRunning`.

**Orientation.** Sensor frames are landscape-native; on iOS capture rotates in
hardware via `connection.videoOrientation = .portrait`, so pushed frames are
720x1280 upright. `PushFrameSource::format()` reads the dimensions of the
last pushed frame (waiting up to 1.5s for capture to start; falls back to
720x1280 on iOS / 1280x720 on macOS) — the H.264 encoder initializes from
the declared dimensions and squashes frames otherwise, never re-reading per
frame. macOS presets are advisory (a 1080p camera ignores `.hd1280x720`),
so `mac/.../CameraPusher.swift` also pins `device.activeFormat` to 1280x720
when offered, and starts pushing BEFORE `media_live_video_start` so the real
dimensions are known at encoder init. The legacy
`media_video_set_rotation`/nokhwa rotation path is dead (FFI deleted). On
the Mac side the `<image>` element binds dynamic `videoWidth`/`videoHeight`
model fields (updated from the image-load result's real dimensions in
`video_image_event`), so any sender orientation renders with correct aspect.

**nokhwa removal (2026-09-09).** Apple platforms no longer compile nokhwa at
all: `iroh-c-ffi/Cargo.toml` gates the capture deps to Linux targets, and
the vendored forks (`vendor/nokhwa`, `vendor/nokhwa-bindings-macos`,
`vendor/block`) are deleted — their patches (iOS unlock, macOS camera-lock
tolerance) only mattered for the nokhwa-on-Apple path. Linux capture uses
crates.io nokhwa transitively via iroh-live's `capture-camera` feature.

**Lesson for scripting launches.** `devicectl ... launch` with launch args
runs automation before the app is active; anything camera-adjacent must wait
for `didBecomeActive` (or be triggered from the UI after launch).

## OS mic indicator stays on after a call ends (2026-09-09, FIXED)

**Symptom.** After hanging up (mac and iOS), the OS microphone-in-use
indicator stayed lit indefinitely; camera capture stopped correctly.

**Root cause.** moq-media's audio driver opens the cpal input device once
and keeps it hot for the process lifetime: `RemoveStream` only detaches the
ring-buffer consumer, it never closes the device. With no release path in
the FFI, the mic stayed open after the first call.

**Fix.** `AUDIO` in `media.rs` is now a droppable `Mutex<Option<AudioBackend>>`;
`media_live_stop` calls `release_audio()` after the encode pipelines shut
down. The driver thread holds only a `weak_tx`, so once the backend and all
streams are dropped the thread exits and cpal closes the device. Next call
re-creates the backend on demand. Safe to call while streams exist — the
driver only exits when every strong sender is gone.
