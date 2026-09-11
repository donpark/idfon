# Video media

Idfon streams live video alongside its audio path. The pipeline is headless
first (file-driven, like the audio file streaming in
[cli-data.md](cli-data.md)); GUI rendering and camera capture come later.

## Live camera capture (iOS + macOS → any receiver)

iOS captures through `ios/Idfon/CameraPusher.swift`: a headless
`AVCaptureSession` (no preview layer) delivers BGRA frames on a serial
delegate queue and pushes each frame over the `media_video_push_frame` FFI
into `PushFrameSource` (`native/vendor/iroh-c-ffi/src/media.rs`), which feeds
the same H.264 encoder ladder / MoQ broadcast as the file path. `VideoCall`
starts/stops the pusher around `media_live_video_start()`/`media_live_stop()`.

macOS mirrors the same pattern (`mac/Sources/Idfon/CameraPusher.swift`):
no orientation lock (sensor-native landscape, declared 1280x720), the session
preset is advisory on macOS so `device.activeFormat` is pinned to 1280x720
when the camera offers it, and capture starts before
`media_live_video_start()` so the encoder's format probe sees real frames.

Key invariants (break these and capture silently stops or distorts):

- **Start only while the app is foregroundActive.** iOS capture arbitration
  denies frames to sessions born inactive — no error, no notification, and
  rebuilding the same session never recovers. `CameraPusher.start()` defers
  to `didBecomeActive` when needed; launch-arg automation (`-camprobe`,
  `-videodial`) must go through the same gate. See
  [troubleshooting.md](troubleshooting.md) for the full post-mortem.
- **Orientation at capture.** `connection.videoOrientation = .portrait`
  rotates in the capture pipeline; pushed frames are 720x1280 upright.
  `PushFrameSource::format()` must declare `[720, 1280]` — the encoder is
  initialized from the declared dimensions and never re-reads them.
- **Drop-latest handoff.** Pushed frames overwrite a shared slot; the
  encoder polls and takes the newest (a slow encoder skips frames instead of
  backing up capture).

The receiver renders by subscribing to the adaptive decoded track
(`media_video_start` in `native/vendor/iroh-c-ffi/src/video.rs` writes
`video-frame.jpg` atomically ~15fps; the GUI re-loads it on a timer through
the image registry with dynamic width/height binding).

## Live-call UI (hybrid: inline stage, tap to expand)

Live streams are ephemeral within a chat — only descriptions of the call
activity are written to the message history — so they render outside the
message list, in a stage below the chat control bar. All three shells share
the same shape:

- **Inline by default.** An audio call shows a status pill with a live
  waveform; a video call/watch shows the stream frames. Native GUI: the
  `liveInline` bar in `native/src/windows/chat.native` (audio → the
  `{waveform}` chart, video → `{videoImageId}`). mac: `liveBar` pill + the
  inline video panel in `mac/Sources/Idfon/ChatViewController.swift` (tap or
  the expand button goes fullscreen). iOS: the 180pt video bar under the nav
  bar in `ios/Idfon/ChatViewController.swift`; SceneDelegate auto-presents
  the ringing screen only on `.incoming` — active calls stay inline until
  expanded.
- **Tap to expand fullscreen.** The stage replaces the chat (native GUI:
  `liveFullscreen` if/else around the whole layout; mac:
  `fullscreenOverlay` over the container; iOS: the existing full-screen
  `CallViewController` with a chevron-down collapse that dismisses while the
  call keeps running). End-call/stop-video controls ride in the stage.
- **Auto-collapse on call end** — `settle()` clears `liveFullscreen` (GUI),
  and `updateLiveUI()` drops out when the call state goes idle (mac).
- mac mic metering: `AudioMeter` (WaveformView.swift) taps the input once
  and fans out to every attached waveform (`add(view:)`) — the inline bar,
  fullscreen stage, and in-call recording bar share the tap; a second engine
  tap would race the mic.

Layout traps hit while building this (see git history): the fullscreen
overlay must be added to the container BEFORE its constraints activate
(orphan-view constraints throw `NSGenericException` and — on mac — abort
`loadView` mid-flight, silently blanking the whole chat detail pane), and a
fullscreen builder must never read `self.view` inside `loadView` (lazy view
re-entry → infinite recursion → SIGSEGV). Same rule on iOS: a new view
needs its `addSubview` even when only its constraints were edited.

## Verified pipeline

```text
fragmented MP4 (CMAF) video file
  → moq-mux fMP4 import (in-memory broadcast)
  → H.264 decode (openh264, software)
  → simulcast encode: one H.264 rendition per preset
    (default ladder 180p/360p/720p, filtered to the source resolution)
  → iroh-live MoQ broadcast (iroh-live: ticket = capability)
  → subscriber picks a rendition (quality parameter)
  → Annex B H.264 elementary stream (.h264), playable with ffplay/mpv
```

New code lives in `crates/idfon-media/src/video.rs`; the daemon methods are
`media.live.publish`/`media.live.subscribe` with `video: true`, driven by:

```sh
# Publish a video file as a broadcast; prints the live ticket.
idfon send --stream --video --file clip.mp4 --name myvideo

# Record the highest rendition as Annex B H.264.
idfon get "$(ticket)" --video --seconds 6 --out rec.h264
idfon get "$(ticket)" --video --quality low --out rec.h264   # mid/high/highest
```

`media.live.publish` also accepts `presets: ["180p", "360p", ...]` to override
the rendition ladder.

## Input requirements and constraints

- **Container**: fragmented MP4 (CMAF) only, for now. Plain progressive MP4s
  need re-muxing:
  `ffmpeg -i in.mp4 -c copy -movflags +frag_keyframe+empty_moov+default_base_moof out.mp4`
- **Codec**: H.264 Baseline, no B-frames — the publish side decodes with
  openh264 (software, all platforms), which supports Baseline only. Encode
  sources with `-profile:v baseline -bf 0`. High-profile/B-frame streams fail
  per-frame decode.
- The whole file is imported into memory at publish start; clips are fine,
  multi-GB files are not (yet).
- File audio is not streamed yet (video-only broadcast).

## Responsive delivery

The publisher emits one rendition per preset, sharing a single decoded source
(simulcast). The subscriber's `--quality` selects the rendition
(low/mid/high/highest; catalogue-ranked by resolution), so constrained
receivers take the low ladder rung instead of stalling. Sender cost scales
with the ladder: fewer presets for weak devices.

Auto rendition switching on the receiver is already provided by iroh-live
(`VideoTrack::enable_adaptation` driven by QUIC path stats) and lands with the
GUI video view; the headless recorder uses fixed-rendition selection.

## Not yet

- File audio (AAC→Opus transcode) alongside the video track
- Hardware codecs (rusty-codecs has a VideoToolbox feature for macOS)
- Passthrough single-rendition publishing (zero-CPU mode for weak senders)
- MKV/TS/FLV/H.264 elementary imports (plumbing exists, untested)
- Incremental import for multi-GB files

## File transfer mime tagging

`media.resource.put` accepts a `mime` parameter persisted next to the
resource and returned by the finish/get responses. The CLI infers it from the
file extension (`idfon put --file clip.mp4` tags `video/mp4`) and accepts
`--mime` to override. `media.resource.register` already carried the full
`MediaResource` (its `codec` field) for GUI callers.
