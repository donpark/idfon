# Idfon (mac)

Native macOS client — Swift + AppKit (no SwiftUI, no Native SDK). Programmatic
UI, mirroring how the iOS app is programmatic UIKit. The app logic is the iOS
app's Swift core (`DaemonClient`, `ChatStore`, `VideoCall`, `VoiceMemo`,
`BlobTransfer`) adapted for the desktop; the Rust media pipeline is the shared
`native/vendor/iroh-c-ffi` dylib, and `idfond` runs as a sibling subprocess
(same default profile/socket as the CLI and the Native SDK GUI:
`/tmp/idfon/idfond.sock`).

## Build & run

```sh
cd mac
./build.sh          # builds the dylib + idfond once, then the .app
open build/Idfon.app
```

Or from the repo root via the pnpm workspace:

```sh
pnpm mac build      # = bash build.sh in mac/
pnpm mac start      # open the built .app
pnpm ios build      # same delegation for the iOS app
pnpm ios start <args> # install + launch on the booted simulator
```

Requires the Rust release artifacts (built on first run) and a Swift 5.9+
toolchain. The bundle ad-hoc signs itself; mic/camera prompts come from the
bundled Info.plist usage descriptions.

## Features (GUI parity)

- **Identities**: list, create, switch (daemon `identities`/`identity.use`);
  message history and cursors reset per identity
- **Peer connections**: add via endpoint-addr ticket with grants both ways;
  peer-details popover with copyable endpoint ID
- **Text chat**: daemon event stream, per-identity persisted cursor,
  outgoing Sent/Failed status
- **Voice memos**: record (AVAudioRecorder, live dotted waveform from real
  metering — port of the iOS `LiveWaveformView`), blob put, IDFON-RECORDING/1
  envelope; received recordings auto-fetched, played via AVAudioPlayer with
  progress on a static waveform
- **Live audio calls**: caller publishes mic through the c-ffi (cpal), callee
  subscribes; IDFON-LIVE/1 envelopes + call_started/stopped signaling
- **Video calls**: publish/watch through the c-ffi (camera frames pushed from
  Swift by `CameraPusher.swift` -> `media_video_push_frame` FFI ->
  `PushFrameSource` — same pattern as iOS; nokhwa is not compiled on Apple
  platforms); decoded frames polled from video-frame.jpg ~10fps; return-leg
  auto-join; message text renders markdown (NSAttributedString, theme-aware)
- **One-way video shares**: publish a fragmented MP4 (`media.live.publish`),
  incoming `media=video` invites offer Watch
- **In-call recording**: daemon-side opus (`media.recording.*` +
  `media.live.recording.store`), engine-tap waveform meter, review-and-send
- **Capability receive tickets** (`capability.ticket`), manual live-ticket
  subscribe, audio settings (volume/bitrate/mic probe/device counts),
  emergency stop (Media menu / sidebar)
- **Stale-invite guard**: invites replayed after a relaunch ring only if
  < 60s old (GUI's drain logic)

Interops with the Native SDK GUI, the iOS app, and the CLI (same daemon).

## Deliberate v1 limits

- Native-GUI voice notes are Opus; AVAudioPlayer can't decode raw Opus, so
  those arrive as voice bubbles but won't play (PCM memos — iOS/mac — do;
  in-call recordings play through the daemon pipeline)
- Audio device switching is counts/probe only — no device-name enumeration
  exists in the FFI (the GUI has the same limitation)
- No system notifications (GUI parity: banners only)