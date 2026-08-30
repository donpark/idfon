# Audio media status

Nufon has a Rust media backend behind the Native SDK app's Zig host and C ABI.
The daemon owns network media sessions, blob providers, resource transfer, and
authorization. The Native SDK application remains TypeScript + Native markup;
Zig dispatches local device/playback commands and daemon IPC. Raw audio samples
do not cross the daemon IPC or the C ABI.

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

The current implementation is macOS-first and has been verified with two simultaneously running app instances sending and playing a short recording. Recording attachments use the custom `nufon-chat/1` ALPN and a length-prefixed bidirectional QUIC stream; the receiver acknowledges a validated envelope with `audio_received` before the sender reports delivery success. Each receiver instance generates a fresh endpoint identity on launch, so two instances may safely share the default development directory for endpoint identity; separate directories are still recommended to isolate media files.

It uses the following app-data files
under `NATIVE_SDK_APP_DATA_DIR` (with `/tmp/nufon` as a development fallback):

- `conversations/<scope>/recording.opus` — local microphone recording;
- `conversations/<scope>/received.wav` — decoded live audio test recording;
- `conversations/<scope>/fetched-recording.opus` — fetched voice recording;
- `conversations/<scope>/recording-history.log` — durable deduplicated recording tickets;
- `conversations/<scope>/blobs/` — provider blob store;
- `conversations/<scope>/fetched-blobs/` — recipient blob store.

The scope is the selected peer endpoint in the current prototype. Local
device/playback state remains process-global, so this isolates persisted data
and broadcast names but does not yet support concurrent active sessions in one
process. Daemon network session records are identity- and conversation-scoped.

## Chat controls

The chat window currently provides:

- microphone start/stop and a microphone sample probe;
- live Opus call start/stop with automatic ticket signaling to the selected peer;
- automatic live ticket subscription/unsubscription for incoming calls;
- `iroh-live` ticket copy and manual subscription controls for debugging;
- local microphone recording start/stop;
- Ogg Opus recording storage through `iroh-blobs`;
- recording attachments with explicit Send/remove controls;
- BlobTicket copy/send/fetch;
- fetched Ogg Opus playback;
- subscriber output volume control.

Live publisher and subscriber shutdown paths call `Live::shutdown()` before
releasing their sessions, including replacement of an active subscriber. This
keeps the underlying Iroh endpoint/router shutdown graceful and avoids the
`Endpoint dropped without calling Endpoint::close` error.

Recording messages use a versioned metadata envelope:

```text
NUFON-RECORDING/1
id=<BlobTicket>
codec=opus
channels=1
sample_rate=48000
duration_ms=<recording duration in milliseconds>
sender_id=<Endpoint ID>
ticket=<BlobTicket>
```

The BlobTicket is the stable recording ID for this prototype: it is
content-addressed and remains unchanged across duplicate delivery. The
receiver validates the ticket before persisting it in the conversation's
recording history ledger. Audio bytes are never placed in the message.
The sender measures the finalized local recording duration and includes it in the envelope. The attachment UI displays the rounded duration in seconds, for example `4 sec audio attached`.

## Verification

Rust media tests cover:

- Ogg Opus headers and packet parsing;
- the recording receiver bidirectional stream, framing, and acknowledgment path;
- Ogg Opus packet decoding with libopus;
- WAV test-recorder finalization;
- persistent blob tags;
- provider-to-recipient BlobTicket transfer.

The Native SDK app has also been tested with automation for microphone capture,
recording, live ticket creation, subscription setup, blob storage, blob
fetching, and two-instance recording delivery/playback. Direct FFI tests also
cover the exact length-prefixed recording envelope and `audio_received`
acknowledgment exchange. A normal Call now starts
an `iroh-live` publisher, sends a `NUFON-LIVE/1` invite containing its ticket
through the existing control channel, and makes the receiver subscribe
automatically. Either participant can end the call: the stop message tears down
the peer subscription, and the receiver's `call_stopped` reply stops the
publisher. The macOS package
includes `NSMicrophoneUsageDescription`. Per-process Zig and Rust diagnostics
are written to `/tmp/nufon-<pid>.log`.

Typical checks:

```sh
scripts/test-rust.sh
scripts/test-media.sh
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

## Current architecture

The daemon owns network media sessions, BlobTicket providers, resource transfer,
and authorization. The GUI owns local microphone/speaker access, playback,
volume/mute, consent, notifications, and emergency stop. The extracted
`nufon-media` crate provides explicit publisher/subscriber and local resource
session handles while the legacy Native SDK local-device backend is migrated.

## Remaining production work

The Phase 7 MVP is implemented. The following production follow-ups remain:

1. **Authorization and local policy** — connect every media action to capability
   grants, expiry, revocation, schedules, and recipient policy. Capability-ticket
   issuance and validation now exist for message receive authorization; media
   actions still need the same ticket enforcement.
2. **Multi-session media state** — capture, playback, subscriptions, and blob
   providers still need fully identity/conversation-keyed active ownership.
   Persisted resource metadata and paths are identity-scoped.
3. **Durable chat history** — move beyond the recording-ticket ledger to a
   durable message model with delivery state, retries, and normal messages.
4. **Recording metadata accuracy** — persist richer metadata such as the exact
   duration and codec details across the recording history ledger.
5. **Device management** — expose device IDs and names, add selection UI, and
   handle disconnect/reconnect status visibly.
6. **Playback UX** — add queueing, pause/resume, progress, completion state, and
   per-recording volume.
7. **Lifecycle hardening** — the `iroh-live` publisher/subscriber shutdown paths
   are graceful; detached Zig workers still need cancellation and joins where
   possible, plus shutdown tests during blocking operations.
8. **Packaging portability** — validate Swift runtime linking on clean Xcode
   installations and CI.
9. **Cross-platform support** — evaluate Linux, Windows, and mobile capture,
   permissions, and output backends.
10. **Blob retention** — add explicit recording deletion, expiration, and
    garbage collection for unreferenced blobs and history entries.
11. **Automated smoke test** — promote the two-process media flow into a
    repeatable isolated test covering capture, decode, non-silent samples,
    BlobTicket transfer, fetched bytes, and playback.
