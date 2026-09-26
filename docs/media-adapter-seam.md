# Media adapter seam

> Design note. Status: **slice #1 landed; in-memory render is the default on
> the iOS/mac shells** (trait seam + FFI callback; device verification
> pending). This describes the interface boundary that lets idfon keep media
> processing native-but-modular: capture, codec, and render are supplied by
> the platform shell (or a bundled fallback), while idfon owns the seam and
> the transport/session logic.

## What shipped

- `crates/idfon-media/src/seam.rs`: `AudioCapture` / `VideoCapture` /
  `VideoRender` traits, `AudioInput`, and bundled `FileAudioCapture` /
  `FileVideoCapture` / `DeviceAudioCapture`.
- `idfon-media` call sites route through the seam (`live.rs`, `video.rs`).
- `iroh-c-ffi` capture adapters (`ShellAudioCapture`, `ShellVideoCapture`)
  route `start_live`; the render loop takes a `Box<dyn VideoRender>` with a
  `DiskRender` fallback (`video-frame.jpg`, used only when no callback is set).
- New FFI: `media_video_set_render_cb` / `media_video_clear_render_cb`
  (`CallbackRender` hands decoded RGBA straight to the shell; `len == 0` = clear).
- iOS/mac Swift register the callback unconditionally and render frames in
  memory; they no longer read `video-frame.jpg`. The Native SDK GUI does not
  register one, so it keeps using the artifact. **Not device-tested.**

## Motivation

idfon already does the right thing for Apple camera capture: Swift pushes
frames over the FFI (`media_video_push_frame`) and Rust encodes/publishes.
The adapter pattern exists, it just is not named or uniformly applied. The
remaining bundled-device paths and the decoded-video path still route through
iroh-live/moq types directly.

The problem is not "native code is bad." Native is correct for QUIC, crypto,
discovery, codecs, and media devices. The problem is that the *interface* to
those native facilities currently lives in upstream crate types
(`moq_media::publish::AudioSource`, `VideoSource`) rather than in idfon. When
moq changes, every shell changes.

## Current bindings (the ledger)

| Current binding | Location | Intended adapter |
|---|---|---|
| `AudioSource::Device(AudioCaptureConfig::default())` | `crates/idfon-media/src/service.rs` (`start_publisher`) | `DeviceAudioCapture` (platform) |
| `AudioSource::Device(… capture::Source::Microphone(INPUT_DEVICE))` | `native/vendor/iroh-c-ffi/src/media.rs` (`start_live`) | `DeviceAudioCapture` |
| `AudioSource::Frames { audio_stream(queue) }` (shell push) | `native/vendor/iroh-c-ffi/src/media.rs` | `ShellAudioCapture` — already adapter-shaped |
| `AudioSource::Frames { AudioFile }` | `crates/idfon-media/src/live.rs` | `FileAudioCapture` (bundled, stays) |
| `VideoSource::Frames(video_stream())` (shell push) | `native/vendor/iroh-c-ffi/src/media.rs` | `ShellVideoCapture` — already adapter-shaped |
| `VideoSource::AnnexB(stream)` | `crates/idfon-media/src/video.rs` (`annexb_source`) | `FileVideoCapture` (bundled, stays) |
| `broadcast.audio().set_with(..)` / `video().set_renditions(..)` | `media.rs`, `service.rs`, `live.rs`, `video.rs` | behind `audio_source()` / `video_source()` |
| `moq_audio::capture::devices()` / `playback::devices()` | `native/vendor/iroh-c-ffi/src/media.rs` | `AudioCapture::devices` / `AudioPlayback::devices` |
| `PLAYBACK_CONTROL` volume | `native/vendor/iroh-c-ffi/src/media.rs` | `AudioPlayback::set_volume` |
| `AudioConsumer::read()` → `write_wav` | `crates/idfon-media/src/live.rs` (`record_remote`) | decode bundled; live sink becomes `AudioPlayback::play` |
| `track.recv()` → JPEG encode → `video-frame.jpg` → GUI timer | `native/vendor/iroh-c-ffi/src/video.rs` | `VideoRender::present` |
| `track.recv()` → re-encode → file | `crates/idfon-media/src/video.rs` (`record_video_track`) | stays (headless recording, not render) |

The FFI push entry points (`media_audio_push_samples`,
`media_video_push_frame`) already are the platform capture adapter. The trait
just gives them a name and routes the device/playback/render paths through
the same shape.

## Proposed seam (owned by idfon)

```rust
use moq_audio::{Format, Frame as AudioFrame};
use moq_video::Frame as VideoFrame;
use n0_future::boxed::BoxStream;

#[derive(Clone, Copy)]
pub struct AudioInput { pub format: Format, pub sample_rate: u32, pub channels: u8 }

/// Capture: shell (or bundled fallback) produces frames the publisher ingests.
pub trait AudioCapture: Send + Sync {
    fn input(&self) -> AudioInput;
    fn frames(&self) -> BoxStream<AudioFrame>;
}
pub trait VideoCapture: Send + Sync {
    fn frames(&self) -> BoxStream<VideoFrame>;
}

/// Render/playback: shell consumes decoded frames.
pub trait AudioPlayback: Send + Sync {
    fn input(&self) -> AudioInput;
    fn play(&self, frame: AudioFrame);
    fn set_volume(&self, volume: f32);
}
pub trait VideoRender: Send + Sync {
    fn present(&self, frame: VideoFrame);
}

/// The only place that knows moq's source enum.
pub fn audio_source(c: &dyn AudioCapture) -> moq_media::publish::AudioSource { /* … */ }
```

Rule: `moq_media::publish::{AudioSource, VideoSource}` appear in exactly one
adapter function. idfon code references the traits.

## What stays bundled

- **Opus** encode/decode. No public Opus encoder in AVFoundation/AudioToolbox.
  Either keep libopus bundled or negotiate a platform codec (AAC) per peer.
  This is the one real fork in the road.
- **Container mux/import** (`moq_mux`). Format parsing; no platform equivalent.
- **File sources** (`AudioFile`/symphonia, `VideoSource::AnnexB`). CLI/headless
  paths, not devices.

## Platform facts that constrain the render seam

- The Native SDK image registry (`@native-sdk/core`) loads `ImageSource` only
  from `path` / `url` / `cachePath` — **no in-memory bytes**. The native GUI
  cannot consume decoded frames directly without a Native SDK change or a
  file-backed handoff. Deleting `video-frame.jpg` for the native GUI is
  therefore not a self-contained idfon slice.
- Swift shells can render in memory (`CGImage`/`CVPixelBuffer` from raw RGBA,
  `AVSampleBufferDisplayLayer`), but need an FFI callback or a memory-slot
  export to receive frames without disk.
- iOS/mac capture already owns the device; only the receive/render side is
  currently file-based.

## Migration order

1. ~~Establish the seam, no behavior change.~~ **Done** (`seam.rs`, adapters,
   routing, `DiskRender` fallback). Verified with seam unit tests.
2. ~~Swift render adapter.~~ **Done**: iOS/mac register the callback and
   render in memory; the file polling is deleted for those shells. Device
   verification still pending — flip back if it regresses.
3. **Native GUI render.** Requires a Native SDK image path from memory, or an
   agreed file/cache handoff. Deferred until the Native SDK supports it.
4. **Device I/O adapter.** Platform capture/playback behind the traits; bundled
   `cpal`/`moq_audio` remains the fallback impl.
5. **Codec adapter.** Only if a platform needs it; gated by capability
   negotiation. Opus stays bundled unless the codec fork is taken.

## Verification

- One `FakeRender` that counts `present()` calls: feed N decoded frames,
  assert N presentations. Fails if the render path drops frames or reverts
  to polling.
- The seam must not change wire behavior: existing live-call E2E
  (mac↔iOS) remains the acceptance test per stage.