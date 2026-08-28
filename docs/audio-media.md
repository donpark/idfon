# Audio media status

Nufon has a Rust-owned media layer behind the Native SDK app's Zig host and C ABI.
The Native SDK application remains TypeScript + Native markup; Zig only dispatches
media commands and receives status/results. Audio samples do not cross the ABI.

## Verified pipeline

```text
macOS microphone
  → Rust AudioBackend/cpal
  → 48 kHz f32 PCM
  ├─ local voice recording → Ogg Opus
  ├─ live publishing → Opus → iroh-live
  └─ subscriber decode → output tee + WAV test recording

completed recording
  → iroh-blobs FsStore
  → persistent named tag
  → BlobTicket
  → recipient downloader
  → local file
```

The current implementation is macOS-first and has been verified with two simultaneously running app instances sending and playing a short recording. Each receiver instance generates a fresh endpoint identity on launch, so two instances may safely share the default development directory for endpoint identity; separate directories are still recommended to isolate media files.

It uses the following app-data files
under `NATIVE_SDK_APP_DATA_DIR` (with `/tmp/nufon` as a development fallback):

- `conversations/<scope>/recording.opus` — local microphone recording;
- `conversations/<scope>/received.wav` — decoded live audio test recording;
- `conversations/<scope>/fetched-recording.opus` — fetched voice recording;
- `conversations/<scope>/recording-history.log` — durable deduplicated recording tickets;
- `conversations/<scope>/blobs/` — provider blob store;
- `conversations/<scope>/fetched-blobs/` — recipient blob store.

The scope is the selected peer endpoint in the current prototype. Media state is
still process-global, so this isolates persisted data and broadcast names but
does not yet support concurrent active sessions in one process.

## Chat controls

The chat window currently provides:

- microphone start/stop and a microphone sample probe;
- live Opus publish/stop and `iroh-live` ticket copy;
- live ticket subscription/unsubscription;
- local microphone recording start/stop;
- Ogg Opus recording storage through `iroh-blobs`;
- BlobTicket copy/send/fetch;
- fetched Ogg Opus playback;
- subscriber output volume control.

Recording messages use a versioned metadata envelope:

```text
NUFON-RECORDING/1
id=<BlobTicket>
codec=opus
channels=1
sample_rate=48000
duration_ms=0
sender_id=<Endpoint ID>
ticket=<BlobTicket>
```

The BlobTicket is the stable recording ID for this prototype: it is
content-addressed and remains unchanged across duplicate delivery. The
receiver validates the ticket before persisting it in the conversation's
recording history ledger. Audio bytes are never placed in the message.
`duration_ms=0` means duration measurement is not yet exposed by the recorder.

## Verification

Rust media tests cover:

- Ogg Opus headers and packet parsing;
- Ogg Opus packet decoding with libopus;
- WAV test-recorder finalization;
- persistent blob tags;
- provider-to-recipient BlobTicket transfer.

The Native SDK app has also been tested with automation for microphone capture,
recording, live ticket creation, subscription setup, blob storage, blob
fetching, and two-instance recording delivery/playback. The macOS package
includes `NSMicrophoneUsageDescription`. Per-process Zig and Rust diagnostics
are written to `/tmp/nufon-<pid>.log`.

Typical checks:

```sh
cargo fmt --manifest-path native/vendor/iroh-c-ffi/Cargo.toml -- --check
cargo test --manifest-path native/vendor/iroh-c-ffi/Cargo.toml --lib
native check native
native build native
native test native
(cd native && native doctor --manifest app.json --strict)
(cd native && native package --target macos --binary zig-out/bin/Nufon --output /tmp/Nufon.app)
```

Direct Rust tests on macOS may need the Xcode Swift 5.5 runtime in
`DYLD_LIBRARY_PATH`; the Native SDK final app link supplies the required SDK
libraries. Xcode currently emits duplicate Swift class warnings during direct
Rust tests.

## Remaining work

These production follow-ups remain:

1. **Authorization and local policy** — connect every media action to capability
   grants, expiry, revocation, schedules, and recipient policy. The emergency
   stop now exists as a local control, but authorization is not implemented.
2. **Multi-session media state** — replace process-global capture, playback,
   subscriptions, and blob providers with identity/conversation keyed state.
   Persisted files are scoped, but active resources remain one-per-process.
3. **Durable chat history** — move beyond the recording-ticket ledger to a
   durable message model with delivery state, retries, and normal messages.
4. **Recording metadata accuracy** — measure duration and persist/display the
   metadata; `duration_ms=0` remains the explicit unavailable value.
5. **Device management** — expose device IDs and names, add selection UI, and
   handle disconnect/reconnect status visibly.
6. **Playback UX** — add queueing, pause/resume, progress, completion state, and
   per-recording volume.
7. **Lifecycle hardening** — replace detached Zig workers with cancellation and
   joins where possible, and test shutdown during blocking operations.
8. **Packaging portability** — validate Swift runtime linking on clean Xcode
   installations and CI.
9. **Cross-platform support** — evaluate Linux, Windows, and mobile capture,
   permissions, and output backends.
10. **Blob retention** — add explicit recording deletion, expiration, and
    garbage collection for unreferenced blobs and history entries.
11. **Automated smoke test** — promote the two-process media flow into a
    repeatable isolated test covering capture, decode, non-silent samples,
    BlobTicket transfer, fetched bytes, and playback.
