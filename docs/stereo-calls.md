# Stereo calls

> Status: **as-built** end to end — the call path (transport seam, shells, the
> panel's media row, stereo-driven re-publish) and stereo voice messages
> (phase 3). **Remaining**: the device E2E pass and the VPIO probe (both need
> hardware).

The hook: almost nobody has ever heard a stereo phone call. Carrier telephony
(VoLTE/EVS included) is mono to this day. Idfon already ships 48 kHz fullband
Opus over MoQ — stereo is the natural next differentiator, and the media stack
underneath is already capable of it. The work is almost entirely in the FFI
seam and the two Swift shells, gated on one hardware/AEC question.

Why legacy phone infra can never retrofit it: the party who benefits most from
stereo is the **listener**, but the party who decides whether stereo is sent is
the **speaker** — and telephony gives that speaker neither a control nor a
reason to pay for it. Idfon flips the alignment: the decision lives on the
speaker's own live panel (the media group below) at effectively zero cost to
them, while stereo rendering downstream is unconditional — the listener gets
the benefit with no setup at all.

## What "stereo call" means

1. **Stereo uplink + downlink per direction** (each side publishes what its
   capture device gives; each side renders what the catalog declares).
2. **Stereo voice messages** (recording + envelope + playback) — cheap, visible.
3. Mono peers keep working unchanged in both directions.
4. **Stereo is a per-call, sender-side choice** (the 2026-10-22 decision): the
   live panel's media row — a radio group **Built-in / Earphone / Speaker /
   Mute** plus a **Stereo** toggle — picks the call's audio state; Stereo sends
   the 2-channel stream. The buttons are offered per contact (user preference ∩
   what the contact is willing to make available), never gated on the hardware
   that happens to be plugged in (the earphone route is assumed available).
   The headset route is where echo is moot — which is what makes phase 1 cheap
   (see the gate section below).

## As-built: the seam carries channels end to end (2026-10-22)

| Layer | Where | Now |
| --- | --- | --- |
| Capture (iOS) | `ios/Idfon/AudioPusher.swift` | converts to the call's channel count (mono sources upmixed when Stereo is on) and pushes interleaved f32 via `media_audio_push_frames`; `retarget(channels:)` switches a live push |
| Capture (mac) | `mac/Sources/Idfon/WaveformView.swift` (`AudioMeter`) | same, lazily rebuilt converter per push |
| FFI push | `crates/iroh-c-ffi/src/media.rs` | `media_audio_push_frames(pcm, frames, channels)`; `media_audio_push_samples` is the mono shorthand; mismatched pushes are dropped; frame = `rate/50 * channels` |
| Publish | `media_live_start_with_profile(…, channels)` | `ShellAudioCapture` declares the layout; Opus bitrate is per channel (32 kbps default → 64 kbps stereo); pcm24k rejects stereo |
| Subscribe | `crates/iroh-c-ffi/src/media.rs` | `decode.channels = None` (catalog count); prebuffer/pts/media-secs math per channel; the jitter shrink drops whole frames only |
| Render (both apps) | `AudioPlaybackSink.swift` | buffers built at the callback's channel count (interleaved → planar) |
| Voice agent plane | `crates/idfon-live-media` | 24 kHz mono PCM frames into ASR/TTS — **stays mono by design** |
| Voice messages | `VoiceMemo.swift` (both apps), `media.rs` recording path, `native/src/core.ts` | 2ch when the mic is; envelope carries `channels=<n>` (derived, never hardcoded); playback honors the WAV header |

Unit tests: `frame_pts_gap_scales_with_channels`,
`stereo_wav_header_declares_two_channels`, `wav_format_reads_the_declared_layout`
(`cargo test -p iroh-c-ffi`).
Compatibility is free in both directions: old mono subscribers downmix a stereo
track (`decode.channels = Some(1)` + `remix`), new subscribers render old mono
publishers as mono — the catalog self-describes.

## Good news: the transport already speaks stereo

- `moq-audio` (Frando/moq `iroh-live-3`) is channel-aware throughout:
  `encode::Input`/`Config` carry `channels` (Opus is created with 1 or 2
  channels), the hang catalog self-describes the channel count per track, and
  `decode::Config::channels` remixes at the decode boundary
  (`remix`: 2→1 average, 1→2 duplicate). Upstream roundtrip tests cover stereo.
- **No wire protocol change is needed for the media track.** Consequences:
  - old mono subscriber + stereo publisher works today (it decodes with
    `channels = Some(1)` and downmixes);
  - new subscriber + old mono publisher works (catalog says 1, render mono);
  - so stereo can ship per-direction, per-device, without a flag day.
- The playback callback ABI already carries channels:
  `AudioPlaybackFn = fn(ctx, ptr, len, sample_rate, channels, pts)` — the
  shells now honor it.
- `PacedPlayback`/`AudioInput` in `crates/idfon-media/src/seam.rs` already size
  buffers as `rate * channels`. `DevicePlayback` (bundled fallback) honors
  `input.channels` already.

Protocol surface considered and skipped: the `IDFON-LIVE/1` invite's
`audio_codec`/`audio_sample_rate` pair. The catalog is authoritative (it
self-describes the channel count), so no `audio_channels` hint was added; an
invite is re-sent unchanged when a mode change re-publishes the leg.

## Work items

### 1. FFI seam (`crates/iroh-c-ffi`) — **landed**

- Push API: `media_audio_push_samples(pcm, samples)` is the mono path and
  `media_audio_push_frames(pcm, frames, channels)` (interleaved f32) the
  stereo-aware one; the publisher's channel count validates pushes.
- `audio_queue`/`audio_stream`: frames = `rate/50 * channels`.
- Subscribe: `decode.channels = None` (catalog count),
  `consumer.channels()` feeds the playback `AudioInput`; prebuffer and the
  WAV writer carry the channel count.

### 2. Swift shells (both apps, duplicated UI code) — **landed**

- `AudioPusher` / `AudioMeter` convert to the mode's channel count and push
  interleaved frames; `AudioPlaybackSink` builds buffers at the callback's
  channel count. Metering reads channel 0 (acceptable).
- Optional follow-up: a holder-signed `voice.audio_modes` capability field so
  “what the contact is willing to make available” is signed rather than derived
  (today: `pcm24k` ⇒ no stereo, else willing; `ContactAudioModes` holds the user's
  per-contact override).

### 3. Voice messages — **landed (phase 3)**

- Recording: `VoiceMemo.swift` (both apps) writes 2ch when the mic is — the iOS
  recorder sizes the wav from the first captured buffer, the mac recorder from
  the default input device's channel count (both clamped to stereo). Built-in
  mics stay mono.
- Envelope: `channels=<n>` in every composer (both Swift chat composers, the
  iOS `-memo` harness, `native/src/core.ts`). The native shell derives it from
  the recording (`media_recording_channels()` rides the
  `media.live.recording.store` completion as `duration\nticket\nchannels`);
  the shells derive it from their recorder.
- Playback at the declared count: `media_recording_play` decodes the wav
  header (channels + sample rate) instead of assuming mono 48 kHz — stereo
  memos play as stereo through the native shell, and the shells' 16 kHz memos
  no longer play chipmunked there. The Swift shells play via `AVAudioPlayer`,
  which honors the header already.
- Recording (native shell): `media_recording_start` records the catalog's
  channel count (2ch when the mic is), matching the shells.

## The real gate: capture hardware + echo cancellation — resolved by routing

Decision: stereo is a headset/earphone feature — sent per call via the live
panel's **Stereo** toggle, with the route rule below deciding capture. That
collapses the hard part:

- **iOS built-in mic is mono for third-party apps.** The iPhone's stereo mic
  pair is consumed by system beamforming; `AVAudioSession` hands apps a
  1-channel input. (Voice Memos' stereo recording is not an open API.) Stereo
  uplink on iPhone therefore means a class-compliant USB-C stereo
  mic/interface or a USB stereo headset (Shure MV88+, Zoom, Røde AI-Micro …).
  AirPods/HFP mics are mono. **macOS**: built-in mic is mono; USB stereo
  headsets/interfaces are common. Same code path, easiest demo rig.
- **AEC vs stereo**: both shells run `setVoiceProcessingEnabled(true)` on the
  input node (VPIO) and use the playback bus as the echo reference — and VPIO
  may mono-downmix or refuse a 2-channel input (unverified; the tap already
  logs `fmt=…Hz/Nch` in `Automation` marks, so the probe is ~20 minutes).
  With a wired/USB headset the echo path is attenuated enough that VPIO is not
  needed, so the design is:
  - **Stereo on, headset route**: plain input tap, no voice processing,
    capture 2 channels (mono devices upmixed);
  - **everything else** (mono stream, or Stereo on a speaker/built-in route):
    today's VPIO mono path — echo safety wins over the channel count there, so
    Stereo on a speaker route sends 2 channels of VPIO-processed audio.
  - Shortcut: the stream layout is fixed at publish; toggling Stereo mid-call
    re-publishes the mic leg and re-sends the invite, and the peer's
    `.calling/.inCall` handler re-joins on the fresh invite. A route change
    alone keeps the call's layout.

Downlink stereo has no such gate: once the far end publishes stereo, both apps
render it, and earphones/headsets give real separation. Rendering stereo to a
mono-ish speaker is harmless.

## Phases and rough effort

| Phase | Content | Status |
| --- | --- | --- |
| 1 | Stereo transport + render: FFI seam, subscribe, Swift capture/render honoring channels | **landed** (unit tests above) |
| 2 | Stereo-driven capture: the panel's Stereo toggle picks the layout; stereo + headset = plain tap (no VPIO) at 2 channels; everything else keeps VPIO | **landed** (re-publish on stereo ↔ mono) |
| 3 | Stereo voice messages + envelope + playback | **landed** |

Bandwidth is a non-issue: Opus stereo speech ≈ 48–64 kbps vs ≈ 24–32 kbps mono
at the same 20 ms cadence; set `Options::bitrate` explicitly rather than
libopus's auto default.

## Verification

- Unit (landed): `cargo test -p iroh-c-ffi` — `frame_pts_gap_scales_with_channels`,
  `stereo_wav_header_declares_two_channels`, `wav_format_reads_the_declared_layout`.
  The panel's radio behavior is covered by the runnable `ios/Checks` +
  `mac/Checks` `LiveActivityBarCheck` programs (per-mode availability,
  set/unset intents).
- Transport E2E (landed, hardware-free): `stereo_tone_roundtrip_keeps_channel_separation`
  pushes a shell-capture L=440 / R=880 Hz stereo tone through the real MoQ
  publish → decode path (opus) and asserts each tone stays in its own channel
  — the tone E2E below minus the devices.
- Device E2E (remaining): two instances on real hardware, L=440 Hz / R=880 Hz
  test tone into a stereo input, verify channel separation at the far end (the
  `Automation` marks log channel counts); mixed test: stereo publisher ↔ old
  mono build (its downmix is `decode.channels = Some(1)`); mid-call stereo ↔
  mono re-publish.
- Probe (remaining): VPIO with 2-channel input format on iOS and macOS — no
  longer blocking (the mode-gated design works either way) but decides whether
  Bluetooth/speaker routes can ever carry stereo.

## Rebuild scope (per `docs/build.md`)

`crates/iroh-c-ffi` (dylib before `idfond`; after an FFI change regenerate
`irohnet.h` with `cargo run --features headers --bin generate_headers`),
`crates/idfon-live-media` / `crates/idfon-media` if touched, then `ios/` and
`mac/` apps and the Native SDK shell (`native/`: `iroh_ffi.zig` + `core.ts`
for the voice-message envelope).
