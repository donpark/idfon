# Audio media status

> Video is documented separately in [video-media.md](video-media.md).

Idfon has a Rust media backend behind the Native SDK app's Zig host and C ABI.
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

The current implementation is macOS-first. Apple-native media handling is now working on the macOS and iOS shells: microphone/camera capture stays in Swift, while the Rust/iroh media bridge owns publishing, subscription, encoding, and playback. A macOS iOS-to-macOS video call has been verified with both sides starting audio-only, enabling video successfully, and routing audio through AirPods. macOS call metering uses one shared `AVAudioEngine` input tap so audio-route changes cannot install competing taps. The macOS app has also been rebuilt successfully after this path was exercised.

The implementation has been verified with two simultaneously running app instances sending and playing a short recording.

For macOS live calls, capture is owned by a process-wide shared `AudioMeter` and is started by the audio/video call state machines, not by the selected chat view. The meter installs one `AVAudioEngine` input tap, converts to 48 kHz mono f32, and pushes samples into the Rust bridge. The meter writes temporary capture diagnostics to `/tmp/idfon-audio-<pid>.log`, including callback counts, one-second RMS, and peak levels. A short end-to-end trace confirmed permission, tap installation, engine start, continuous callbacks, and PCM delivery to the media queue. Automatic gain normalization remains deferred; the current path retains a modest 2× measurement gain with peak clamping. Recording attachments use the custom `idfon-chat/1` ALPN and a length-prefixed bidirectional QUIC stream; the receiver acknowledges a validated envelope with `audio_received` before the sender reports delivery success. Each receiver instance generates a fresh endpoint identity on launch, so two instances may safely share the default development directory for endpoint identity; separate directories are still recommended to isolate media files.

It uses the following app-data files
under `NATIVE_SDK_APP_DATA_DIR` (with `/tmp/idfon` as a development fallback):

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
record, and call back without adding the peer as a channel first.

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
IDFON-RECORDING/1
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
an `iroh-live` publisher, sends a `IDFON-LIVE/1` invite containing its ticket
through the existing control channel, and makes the receiver subscribe
automatically. Either participant can end the call: the stop message tears down
the peer subscription, and the receiver's `call_stopped` reply stops the
publisher. The macOS package
includes `NSMicrophoneUsageDescription`. Per-process Zig and Rust diagnostics
are written to `/tmp/idfon-<pid>.log`.

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
(cd native && native package --target macos --binary zig-out/bin/Idfon --output /tmp/Idfon.app)
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
and authorization. The caller owns local microphone/speaker/camera access,
playback, volume/mute, consent, notifications, and emergency stop. The extracted
`idfon-media` crate provides explicit publisher/subscriber and local resource
session handles while the legacy Native SDK local-device backend is migrated.

### Capture ownership and lifecycle authority

Device capture (microphone, camera) belongs to the **caller** process, never the
daemon. Two load-bearing reasons:

- **Consent and locality.** A daemon that can open a device can be made to
  capture by any grant-holder or headless/automated client, with no user at the
  device; the daemon may also be remote, shared, or have no microphone at all.
  The daemon is "the network that exists even when no app is running"
  ([daemon.md](daemon.md)) — device capture is the opposite: it only exists
  alongside a live user session. Raw device samples never cross the
  **daemon IPC**; shell-owned capture feeds the pipeline over the C ABI push
  path (see "Sources are pluggable" below).
- **Lifecycle authority.** Only the caller can observe and enforce the events
  that end capture — user intent, foreground state, permission (TCC)
  revocation, audio-route/interruption changes, app suspension or kill. A daemon
  that holds capture manages a lifetime it cannot observe, producing shadow
  state, defensive lifetime pinning, and daemon policy forced by client state.
  Rule: **authority follows observation** — a component should only hold a
  resource whose lifetime it can enforce.

The daemon does not capture today: `idfon-media` is headless by construction
("without a capture device") and `media.live.publish` requires a `file`. cpal
capture lives in the caller-linked `iroh-c-ffi` (`AudioBackend`/`InputStream`),
and Apple microphone/camera capture is shell-owned: Swift uses `AVAudioEngine`
and `AVCaptureSession`, then pushes audio/video frames through the FFI. When
CLI microphone or camera input lands, capture goes in `idfon-cli` (or a
caller-linked source), **not** as a `capture` feature in
`idfon-media`/`idfond`. Pipeline placement may vary; the daemon receives a
session handle or ticket, never a device.

### Sources are pluggable

The pipeline takes a **source**, not a device. `iroh-live` already models this:
`AudioRenditions::empty(source)` accepts any `AudioSource`, and the repo has
three (`MuteSource` = mic, `AudioFileSource`, `PushFrameSource` = pushed video
frames). The exported boundary, though, still pins concrete sources:

| surface | accepted source |
|---|---|
| FFI `media_live_start(audio, video)` | `AudioBackend::default_input()` — the default cpal device, selectable only among cpal devices (`media_audio_switch_input`) |
| daemon `media.live.publish {file}` | a file path |

So the app can choose among local cpal devices and nothing else: a remote audio
stream, a peer's inbound stream, synthesized/mixed/processed audio, or TTS output
cannot be the outgoing source without editing Rust. Plug-and-play was blocked at
the boundary, not in the core ([issue #12](https://github.com/donpark/idfon/issues/12)).

The boundary now takes a **source handle**. Implemented in
`native/vendor/iroh-c-ffi/src/media.rs` (mirroring the video push path):

```c
void  media_audio_push_samples(float const *pcm, size_t samples); // mono 48 kHz f32
char *media_live_start_with_source(uint8_t audio, uint8_t video, char const *source); // "mic" | "push" | "file:<path>" | "ticket:<live-ticket>"
```

`PushAudioSource` drains a caller-pushed queue in `pop_samples` (wait for data
instead of a free-running timer — the encoder is clocked by capture; see the
latency design below). Any holder of samples — a shell tap, a decoded remote
stream, a file, a synth — can now feed the encoder with no new Rust source
type. `media_live_start` is unchanged and still means `"mic"`.

- `mic` — the default local capture device;
- `push` — caller-pushed mono 48 kHz f32 PCM;
- `file:<path>` — a local WAV/MP3 file decoded and published once;
- `ticket:<live-ticket>` — subscribe to a remote live audio ticket, decode it,
  and relay the samples into this publisher.

The Apple shells use `push`; the file and ticket kinds are available to any
caller linked against the C ABI. A ticket source is intentionally a live
stream ticket, not a blob ticket: blob tickets identify completed content and
belong on the file/attachment path.

This generalises the rule above: **the pipeline takes a source handle, and
whoever can observe that source's lifetime owns it.** A local mic/camera belongs
to the caller; a remote stream is a legitimate daemon resource (its lifetime is
network-observable); a file belongs to whoever opened it. The daemon file
publish and the FFI device publish become the same operation with different
source handles.

## Latency design (WebRTC-shaped)

The live-call path targets ~100-120 ms mouth-to-ear and, more importantly, does
not ratchet upward after stalls. The shape follows WebRTC (verified E2E
2026-09-20), and each piece exists because its absence was observed in the
field:

- **Sender side has no jitter buffer.** Capture pushes at real-time 48 kHz, so
  queue depth *is* latency in samples. `pop_samples` waits for a frame's worth
  of data (2 ms poll) instead of pacing with a free-running 20 ms timer — timer
  overshoot made the consumer fall permanently behind capture, growing backlog
  to the old 2 s capacity. The queue itself (`AUDIO_QUEUE`) is only an
  allocation clamp now.
- **Trim lives on the capture callback**, not in the pump. The pump stops being
  polled under encoder/network backpressure, so any trim inside it never runs
  exactly when it is needed; `media_audio_push_samples` runs in real time no
  matter what and clamps depth to an adaptive target (2× the largest observed
  capture burst, floor 40 ms). A device that ignores the 10 ms IO request
  therefore gets a bigger target instead of having its bursts chopped.
- **10 ms capture IO both platforms** (VoIP standard): mac sets
  `kAudioDevicePropertyBufferFrameSize=512` on the default input device
  (WaveformView); iOS sets `setPreferredIOBufferDuration(0.01)` (AudioPusher).
  The mac tap otherwise delivered 4800-frame (~100 ms) bursts, which dominated
  sender latency.
- **Receiver playout must shrink.** The moq-audio sink parks ahead-writes and
  never drains back on its own — after a stall + recovery burst the parked
  delay was permanent, and stacked toward the 5 s observed in the field. The
  decode loop now discards down to an 80 ms playout target before
  `sink.write` (plain drop; time-stretch is the upgrade path).
- Fixed costs: 20 ms Opus frames, ~50 ms sink device buffer, one-time 50 ms
  startup prebuffer, decoder `latency_max` 50 ms (a skip threshold, not added
  delay).

End-of-call `audio queue gaps: overflow_samples=` in the daemon log is the
health signal: nonzero means trims fired (stalls happened); steady state is 0.

## Live streaming through the daemon (synthetic, no microphone)

`scripts/stream-e2e.sh` exercises the live path end to end through the real
daemon protocol and CLI, no GUI or capture device:

1. generates (or accepts as `$1`) a WAV — by default a 1 kHz pip every 2 s;
2. publishes it via `idfon send --stream [--file FILE | stdin] [--loop]`, which calls
   the daemon's `media.live.publish` (symphonia decode → Opus encode →
   iroh-live broadcast) and prints the live ticket — the ticket is the
   subscriber capability, no pairing needed;
3. subscribes via `idfon get TICKET [--out FILE] [--seconds N]`, which calls
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
`scripts/fanout-e2e.sh` baselines direct fan-out: N concurrent listeners
(default 1/4/16, `SIZES` env) on one publisher with `--no-relay`, every
listener gated on the playback-UX metrics. A media relay
(iroh-live-relay) is only needed later, when publisher egress — not the
relay — becomes the bottleneck. `scripts/geo-fanout.sh` extends this to
true internet fan-out: N ephemeral Vercel Sandbox VMs each run the Linux
listener against a local publisher (relays on for rendezvous/hole-punch)
and report per-listener UX metrics. Baselines (see docs/cli-data.md for
tables and limits): 16 concurrent loopback listeners and 6 concurrent
internet listeners both complete with zero stalls, zero timeline holes,
and sub-30ms required prebuffers — direct fan-out shows no UX degradation
at these scales.

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
