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
- `conversations/<scope>/fetched-blobs/<hash>.opus` — fetched recordings,
  one file per content hash;
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
- local microphone recording start/stop;
- Ogg Opus recording storage through `iroh-blobs`;
- a Messages-style composer with three states: an idle pill (record button
  swaps to a send arrow while typing), a red recording bar with a live bar
  waveform and elapsed timer, and a playback pill (discard, preview, send)
  once the recording is stored;
- recording attachments that appear as play/stop buttons in the message
  thread (voice messages), playable on both sides once the blob is local;
  recordings can be captured and sent while a call is active (see muting
  below);
- fetched Ogg Opus playback, one playback at a time — a new play supersedes
  the previous one;
- subscriber output volume control.

Chat is symmetric once a peer reaches the GUI: an inbound message, call, or
recording adopts the sender as the send target, so the callee can reply,
record, and call back without adding the peer as a connection first.

Live publisher and subscriber shutdown paths call `Live::shutdown()` before
releasing their sessions, including replacement of an active subscriber. This
keeps the underlying Iroh endpoint/router shutdown graceful and avoids the
`Endpoint dropped without calling Endpoint::close` error.

### Mid-call recording muting

Recording is allowed while a call is active: some users prefer to compose a
voice message instead of speaking ad-hoc. Because the live publisher and the
local recorder would otherwise share the microphone, and there is no echo
cancellation, `iroh-c-ffi/src/media.rs` mutes both directions while
`LOCAL_RECORDING` is active:

- a `MuteSource` wrapper between the capture device and the live Opus encoder
  zeroes microphone samples toward the peer — the peer hears silence while you
  record;
- the subscriber's output sink skips speaker playback — peer audio does not
  bleed into the recording. The subscribed-call WAV recording on disk keeps
  running throughout.

Both mutes lift automatically when the recording stops; a call active before
the recording continues afterwards.

Voice message playback is content-addressed: `media.blob.fetch` exports to
`fetched-blobs/<hash>.opus` and `media.recording.play` takes the blob ticket,
fetches on demand, and supersedes any current playback. Replaying an already
local recording does not re-download it. The blob-serving provider (live
endpoint + FsStore + router) is created once per process and reused across
recordings — reopening the store while the previous instance is shutting down
deadlocks on `blobs.db`, which made every recording store after the first hang.

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
The sender measures the finalized local recording duration and includes it in the envelope. Received recordings render inline in the thread as a play button once fetched; sent recordings are appended when the daemon acknowledges delivery.

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
scripts/test-e2e.sh
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
Rust tests because the media dependencies need the Xcode Swift 5.5 runtime
alongside macOS's system Swift runtime. The runtime path is required for the
tests to execute successfully; the warning is environmental rather than an
application diagnostic.

## Current architecture

The daemon owns network media sessions, BlobTicket providers, resource transfer,
and authorization. The GUI owns local microphone/speaker access, playback,
volume/mute, consent, notifications, and emergency stop. The extracted
`nufon-media` crate provides explicit publisher/subscriber and local resource
session handles while the legacy Native SDK local-device backend is migrated.

## Live streaming through the daemon (synthetic, no microphone)

`scripts/stream-e2e.sh` exercises the live path end to end through the real
daemon protocol and CLI, no GUI or capture device:

1. generates (or accepts as `$1`) a WAV — by default a 1 kHz pip every 2 s;
2. publishes it via `nufon stream [--file FILE | stdin] [--loop]`, which calls
   the daemon's `media.live.publish` (symphonia decode → Opus encode →
   iroh-live broadcast) and prints the live ticket — the ticket is the
   subscriber capability, no pairing needed;
3. subscribes via `nufon listen TICKET [--out FILE] [--seconds N]`, which calls
   `media.live.subscribe` (iroh-live subscribe with retry → Opus decode →
   48 kHz mono WAV + per-packet arrival timings);
4. reports pip count, decode jitter, packet-arrival jitter, and a latency
   estimate (~±0.2 s, pip-phase method), and writes the decoded WAV for ear
   checks — pass a speech sample as `$1` for voice-quality listening.

`scripts/audio-quality.sh` goes further: it synthesizes speech with macOS
`say` TTS, streams it through the same path, aligns the decoded recording
to the source (envelope + sample-domain cross-correlation), and scores the
round trip objectively:

- envelope correlation (speech-intelligibility proxy, PASS >= 0.85)
- segmental SNR over active speech frames (PASS >= 12 dB; Opus HQ loopback
  measures ~20 dB)
- high-band energy above 8 kHz relative to total, source vs decoded
  (fullband check)

Every `listen` capture also records playback-UX metrics in the daemon
response: `subscribe_ms`/`startup_ms` (time to established session and to
the first packet), `max_gap_ms` and `stalls_over_100ms` (arrival stalls —
a fully-received stream can still have stuttered), `missing_packets`
(pts-timeline holes), and `prebuffer_ms` (smallest play buffer that would
have avoided an underrun given the observed arrival schedule).
`scripts/stream-e2e.sh` gates on these (startup < 2 s, max gap < 500 ms,
no stalls, no holes, prebuffer < 200 ms).

Artifacts are kept for ear checks: `audio-source.wav`,
`audio-decoded.wav`, `audio-aligned.wav`, metrics in `audio-quality.json`.
`--voice NAME` picks a different macOS TTS voice, `--seconds N` the
capture window.

```sh
scripts/stream-e2e.sh              # pip pattern, ~60 s total
scripts/stream-e2e.sh speech.wav   # voice quality source (looped)
DURATION=30 scripts/stream-e2e.sh
```

Publishers live in an in-memory daemon registry until `media.live.stop`.
The publisher holds the `LocalBroadcast` for the session's lifetime; dropping
it tears down the catalog and breaks new subscribers (iroh-live contract).
Mic input is a later extension: `AudioBackend::default()` opens the default
input device (macOS mic permission), which the file path avoids.
Multi-subscriber fan-out is a follow-up: `N` listeners on one ticket measure
per-peer delivery.

## Remaining production work

The Phase 7 MVP is implemented. The following production follow-ups remain:

1. **Authorization and local policy** — connect every media action to capability
   grants, expiry, revocation, schedules, and recipient policy. Capability-ticket
   issuance and validation now exist for message receive authorization,
   including signed-claim, subject, issuer, expiration, and revocation checks;
   media actions still need the same ticket enforcement. Interim policy: a
   pairing grant (`MessageSend`) authorizes live-audio calls to that peer; the
   callee's `liveAutoAccept` is the consent gate for incoming calls. No code
   path currently issues `LiveAudioSubscribe` grants, so explicit per-capability
   call authorization remains future work.
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
12. **Real waveform levels** — the recording bar's waveform is a
    deterministic bar pattern stepped by the event poll, not microphone
    levels; drive it from the recorder's peak (already tracked in
    `LOCAL_RECORDING`) through a faster timer for true VU behavior.
