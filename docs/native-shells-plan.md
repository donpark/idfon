# Native App Shells: Platform Plan

Status: planning → execution (iOS first).

## Strategy

One Rust core, thin native shells. The idfon daemon (crates/) owns transport,
identity/peers, capabilities, blob store, media pipeline, operations, and
events. Platform apps are thin shells over the daemon's JSON IPC protocol:

| layer | owned by | ported per platform? |
|---|---|---|
| transport, messaging, capabilities, blobs, media, ops | Rust daemon (`crates/`) | no |
| JSON IPC protocol (`idfon-protocol`) | Rust + documented contract | no |
| C ABI (`native/vendor/iroh-c-ffi`) | 4 functions: `idfon_daemon_run`, `idfon_client_request`, `idfon_client_socket_path`, `idfon_client_result_free` | no |
| IPC client wrapper | shell | yes (~100 lines) |
| views, navigation, audio-session glue, backgrounding UX | shell | yes |

Rule (thin-shell discipline): **if a behavior lives in the daemon's domain, it
goes in Rust.** Shell-side workarounds that a second platform would have to
copy are defects. Protocol gaps discovered by a shell are fixed in the
protocol, then consumed by every shell.

## Platform sequence

1. **iOS** — Swift + UIKit. First shell; validates the C ABI and protocol
   contract that every later shell inherits.
2. **Android** — Kotlin + Compose; daemon via cargo-ndk + thin JNI shim over
   the same C ABI. Cheap once iOS has proven the surface.
3. **macOS** — Mac Catalyst of the iOS app if UIKit-idiomatic code is kept;
   the existing Native SDK desktop app remains the working desktop frontend
   and the protocol's reference implementation until then.
4. **Windows/Linux** — deferred, same pattern.

## Keystone actions

- **Protocol contract**: `docs/protocol.md` documents every method
  (params/result shapes, error codes, cursor semantics), `PROTOCOL_VERSION`
  bump discipline, and what `test-cli.sh` asserts. Written before a second
  frontend depends on it.
- **Stable C ABI**: the four functions are the boundary. Likely addition:
  streaming events (persistent connection for `events --follow`); alternative
  is shells implementing the length-prefixed JSON framing natively. Decide at
  first need, not speculatively.

## Cross-platform shell patterns (design once, use everywhere)

- **Backgrounding/reconciliation**: shells suspend; the daemon persists.
  Persist the event cursor locally, replay `events --after <cursor>` on
  foreground, reconcile operations by id (`operation get`). Ops are already
  durable daemon-side; shells never assume in-flight state survived.
- **Call screen contract**: shell owns audio-session activation and capture
  taps; the daemon owns the media pipeline. Narrow interface:
  dial/answer/stop + level metering.
- **Later, protocol-level**: incoming-call reachability when the app process
  is dead (VoIP push + relay-side support). Not a shell-layer problem.

## iOS app (Swift + UIKit)

Milestones, on branch `ios-app`:

- **M1 skeleton + daemon embed**: Xcode project in `ios/` (repo root, sibling
  of `native/`; file-synchronized groups), link `libiroh_c_ffi.a` (aarch64-ios-sim; build flags per
  `scripts/build-ios-sim.sh` — `CARGO_PROFILE_RELEASE_LTO=off`), start the
  daemon on a background thread at launch, socket + data dir under
  `NSTemporaryDirectory()` (sandbox-safe paths). Done = Swift `status`
  request returns `ready:true`.
- **M2 IPC client + chat screen**: `DaemonClient` actor wrapping the C calls
  (three-layer structure: client ↔ view models ↔ views, mirroring the future
  Kotlin layout); Peer List → Chat via `UINavigationController`; chat screen
  ports `windows/chat.native` as spec; event-cursor persistence + foreground
  replay. `docs/protocol.md` written alongside.
- **M3 live call**: dial/answer over `media.live.dial`/answer methods;
  `CADisplayLink` waveform from `AVAudioEngine` taps; AVAudioSession
  `playAndRecord` + `NSMicrophoneUsageDescription`.
- **M3.5 voice messages (shipped)**: Messages-style composer (growing text
  input, mic button, record/review/send states, dotted waveform in recording
  red and playback gray); shell records via AVAudioRecorder, sends as
  chunked blob + IDFON-RECORDING/1 envelope; received recordings playable
  via chunked blob fetch. Verified: 3.16s memo from simulator mic received
  on the Mac and fetched as a valid wav.
- **M4 device build**: aarch64-apple-ios staticlib, signing, entitlements,
  background-audio mode.

### iOS-only concerns (never ported)

AVAudioSession interruption/route handling, Info.plist/entitlements, TestFlight
distribution, cpal iOS backend quirks (buffer sizes, activation ordering).

### Known risks

- iOS app suspension kills in-process daemon sockets; reconciliation pattern
  above is the answer, edge cases verified on device.
- cpal-on-iOS is niche: activation ordering and buffer sizing may need
  iteration.
- VoIP push for dead-app incoming calls: deferred, needs relay support.
