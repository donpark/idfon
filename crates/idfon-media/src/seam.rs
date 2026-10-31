//! Platform adapter seam for media capture and rendering.
//!
//! idfon code depends on these traits and constructors. Only this module (and
//! the concrete adapter impls) references upstream `moq_media`/`moq_audio`
//! source and sink enums, so a moq change lands here instead of in every shell.
//!
//! Capture adapters are constructed once and consumed into a source; render
//! adapters are live sinks invoked per decoded frame.

use std::collections::VecDeque;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use moq_audio::{Format, Frame as AudioFrame};
use moq_media::publish::{AudioSource, VideoSource};
use moq_video::Frame as VideoFrame;
use n0_future::boxed::BoxStream;

/// Audio format the capture side produces / the playback side consumes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioInput {
    pub format: Format,
    pub sample_rate: u32,
    pub channels: u32,
}

/// Capture side: produces the [`AudioSource`] a publisher ingests.
pub trait AudioCapture: Send {
    fn into_source(self: Box<Self>) -> AudioSource;
}

/// Capture side: produces the [`VideoSource`] a publisher ingests.
pub trait VideoCapture: Send {
    fn into_source(self: Box<Self>) -> VideoSource;
}

/// Decoded video sink: platform renderer, disk artifact, or test double.
pub trait VideoRender: Send + Sync {
    fn present(&self, frame: VideoFrame);
    /// No live frames are available any more (peer camera off / track ended).
    fn clear(&self) {}
}

/// Decoded-audio sink: platform playback or the bundled device engine.
///
/// `write` takes interleaved PCM in `input()`'s layout, already gain-applied
/// by the caller. `buffered` is the sink's lead over the speaker (zero for
/// sinks that pace themselves).
pub trait AudioPlayback: Send {
    fn input(&self) -> AudioInput;
    fn write(&mut self, pcm: &[u8], pts_us: u64) -> anyhow::Result<()>;
    fn buffered(&self) -> Duration {
        Duration::ZERO
    }
    fn set_volume(&mut self, volume: f32) {
        let _ = volume;
    }
}

/// A frame-stream audio source (shell push or file decode).
/// Jitter-buffered playout in front of a raw emit closure — the "real jitter
/// buffer" a shell playback adapter needs (docs/media-adapter-seam.md): the
/// per-frame adapter that was tried and reverted handed frames to the shell as
/// they arrived, and arrival jitter crackled.
///
/// `write` queues interleaved PCM; a pacing thread emits it to `emit` in
/// `PLAYOUT_CHUNK`-sized pieces at media rate after a prebuffer that adapts
/// to recent arrival jitter between [`PLAYOUT_TARGET_MIN`] and
/// [`PLAYOUT_TARGET_MAX`] (starting at [`PLAYOUT_TARGET`]).
/// `buffered` reports the queue so the caller can trim after a stall. On
/// overflow the oldest audio drops back to the current target, so latency
/// cannot ratchet after a burst.
pub struct PacedPlayback {
    input: AudioInput,
    shared: Arc<PacedState>,
    thread: Option<std::thread::JoinHandle<()>>,
}

struct PacedState {
    queue: std::sync::Mutex<VecDeque<u8>>,
    wake: std::sync::Condvar,
    done: std::sync::atomic::AtomicBool,
    /// f32 bits; applied at emit so `set_volume` is safe mid-stream.
    volume: std::sync::atomic::AtomicU32,
    /// Arrival jitter behind the adaptive prebuffer target.
    jitter: std::sync::Mutex<ArrivalJitter>,
    /// Adaptive prebuffer target in microseconds: the write side computes it,
    /// the pacing thread reads it at each (re)prebuffer.
    target_us: std::sync::atomic::AtomicU64,
    emit: Box<dyn Fn(&[u8]) + Send + Sync>,
}

/// Prebuffer before the first emit (and after an underrun): enough to ride
/// out arrival jitter without adding perceptible latency. The starting
/// value; [`ArrivalJitter`] adapts it as arrivals show their real jitter
/// (docs/media-adaptation.md §C8).
const PLAYOUT_TARGET: Duration = Duration::from_millis(50);
/// Adaptive target floor: perfect arrivals still deserve a little lead.
const PLAYOUT_TARGET_MIN: Duration = Duration::from_millis(30);
/// Adaptive target ceiling: past this, latency costs more than the jitter.
const PLAYOUT_TARGET_MAX: Duration = Duration::from_millis(150);
/// How much audio one emit carries; the pacing granularity.
const PLAYOUT_CHUNK: Duration = Duration::from_millis(20);
/// Queue ceiling: after a stall plus a burst, drop the oldest audio back to
/// `PLAYOUT_TARGET` instead of playing it seconds late.
const PLAYOUT_MAX: Duration = Duration::from_millis(250);

/// Recent arrival jitter of [`PacedPlayback::write`] calls: how far each
/// write's wall-clock spacing drifted from its media spacing. The p95 is the
/// lead playout needs to stop that jitter from draining the queue dry.
struct ArrivalJitter {
    /// Deviation samples in microseconds; the percentile's memory (~2.5 s of
    /// 20 ms frames).
    samples: std::collections::VecDeque<u64>,
    /// Previous write's arrival and media stamp.
    last: Option<(std::time::Instant, u64)>,
}

impl ArrivalJitter {
    const WINDOW: usize = 128;

    fn new() -> Self {
        Self {
            samples: std::collections::VecDeque::new(),
            last: None,
        }
    }

    /// One write's arrival. Writes without media spacing (`pts_us` of 0 or a
    /// repeat) say nothing about jitter and are skipped.
    fn record(&mut self, now: std::time::Instant, pts_us: u64) {
        if let Some((last_now, last_pts)) = self.last {
            let media_us = pts_us.saturating_sub(last_pts);
            if media_us > 0 {
                let wall_us = now.duration_since(last_now).as_micros().min(u128::from(u64::MAX)) as u64;
                self.samples.push_back(wall_us.abs_diff(media_us).min(1_000_000));
                if self.samples.len() > Self::WINDOW {
                    self.samples.pop_front();
                }
            }
        }
        self.last = Some((now, pts_us));
    }

    /// The prebuffer a recent p95 of arrivals needs, clamped. The default
    /// until there is a meaningful sample set.
    fn target(&self) -> Duration {
        if self.samples.len() < 16 {
            return PLAYOUT_TARGET;
        }
        let mut sorted: Vec<u64> = self.samples.iter().copied().collect();
        sorted.sort_unstable();
        let p95 = sorted[(sorted.len() * 95) / 100];
        Duration::from_micros(p95).clamp(PLAYOUT_TARGET_MIN, PLAYOUT_TARGET_MAX)
    }
}

impl PacedPlayback {
    /// `emit` is called on the pacing thread with borrowed interleaved PCM;
    /// copy before returning.
    pub fn new(input: AudioInput, emit: Box<dyn Fn(&[u8]) + Send + Sync>) -> Self {
        let shared = Arc::new(PacedState {
            queue: std::sync::Mutex::new(VecDeque::new()),
            wake: std::sync::Condvar::new(),
            done: std::sync::atomic::AtomicBool::new(false),
            volume: std::sync::atomic::AtomicU32::new(1f32.to_bits()),
            jitter: std::sync::Mutex::new(ArrivalJitter::new()),
            target_us: std::sync::atomic::AtomicU64::new(PLAYOUT_TARGET.as_micros() as u64),
            emit,
        });
        let thread_shared = shared.clone();
        let bytes_per_ms = Self::bytes_per_ms(input);
        let thread = std::thread::spawn(move || Self::drain(&thread_shared, bytes_per_ms));
        Self {
            input,
            shared,
            thread: Some(thread),
        }
    }

    /// Interleaved f32 PCM, matching [`AudioInput::format`] (the only layout
    /// the decode loop produces).
    fn bytes_per_ms(input: AudioInput) -> usize {
        input.sample_rate as usize * input.channels as usize * 4 / 1000
    }

    fn drain(shared: &PacedState, bytes_per_ms: usize) {
        let chunk = PLAYOUT_CHUNK.as_millis() as usize * bytes_per_ms;
        let mut started = false;
        let mut next = std::time::Instant::now();
        loop {
            let mut queue = shared.queue.lock().unwrap();
            while !started {
                if shared.done.load(std::sync::atomic::Ordering::Relaxed) {
                    return;
                }
                // The target adapts on the write side; re-read it each wait so
                // a grown prebuffer takes effect at the next (re)prebuffer.
                let target = (shared.target_us.load(std::sync::atomic::Ordering::Relaxed) as usize * bytes_per_ms) / 1000;
                if queue.len() >= target {
                    break;
                }
                queue = shared.wake.wait(queue).unwrap();
            }
            if shared.done.load(std::sync::atomic::Ordering::Relaxed) {
                return;
            }
            started = true;
            let now = std::time::Instant::now();
            if now < next {
                // Wakes early on new data or shutdown; the deadline is re-checked.
                let (guard, _) = shared.wake.wait_timeout(queue, next - now).unwrap();
                queue = guard;
                continue;
            }
            let take = queue.len().min(chunk);
            let data: Vec<u8> = queue.drain(..take).collect();
            drop(queue);
            if take == 0 {
                // Underrun: re-prebuffer instead of burst-catching-up.
                started = false;
                next = std::time::Instant::now();
                continue;
            }
            next += PLAYOUT_CHUNK;
            if next < std::time::Instant::now() {
                next = std::time::Instant::now();
            }
            let volume = f32::from_bits(shared.volume.load(std::sync::atomic::Ordering::Relaxed));
            if volume == 1.0 {
                (shared.emit)(&data);
            } else {
                let mut scaled = Vec::with_capacity(data.len());
                for sample in data.chunks_exact(4) {
                    let value = f32::from_le_bytes([sample[0], sample[1], sample[2], sample[3]]);
                    scaled.extend_from_slice(&(value * volume).to_le_bytes());
                }
                (shared.emit)(&scaled);
            }
        }
    }
}

impl Drop for PacedPlayback {
    fn drop(&mut self) {
        self.shared
            .done
            .store(true, std::sync::atomic::Ordering::Relaxed);
        self.shared.wake.notify_all();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl AudioPlayback for PacedPlayback {
    fn input(&self) -> AudioInput {
        self.input
    }

    fn write(&mut self, pcm: &[u8], pts_us: u64) -> anyhow::Result<()> {
        {
            let mut jitter = self.shared.jitter.lock().unwrap();
            jitter.record(std::time::Instant::now(), pts_us);
            let target = jitter.target();
            self.shared
                .target_us
                .store(target.as_micros() as u64, std::sync::atomic::Ordering::Relaxed);
        }
        let mut queue = self.shared.queue.lock().unwrap();
        queue.extend(pcm.iter().copied());
        let per_ms = Self::bytes_per_ms(self.input);
        let max = PLAYOUT_MAX.as_millis() as usize * per_ms;
        if queue.len() > max {
            let keep = (self.shared.target_us.load(std::sync::atomic::Ordering::Relaxed) as usize * per_ms) / 1000;
            let excess = queue.len() - keep;
            queue.drain(..excess);
        }
        drop(queue);
        self.shared.wake.notify_one();
        Ok(())
    }

    fn buffered(&self) -> Duration {
        let queued = self.shared.queue.lock().unwrap().len();
        let per_ms = Self::bytes_per_ms(self.input).max(1);
        Duration::from_millis((queued / per_ms) as u64)
    }

    fn set_volume(&mut self, volume: f32) {
        self.shared
            .volume
            .store(volume.to_bits(), std::sync::atomic::Ordering::Relaxed);
    }
}

pub fn audio_frames(input: AudioInput, frames: BoxStream<AudioFrame>) -> AudioSource {
    // shortcut: channels outside 1..=8 label as Mono instead of erroring at
    // encode open; upgrade audio_frames to Result if a caller needs the error.
    let layout = moq_audio::Layout::from_channels(input.channels).unwrap_or(moq_audio::Layout::Mono);
    let mut encode_input = moq_audio::encode::Input::new(input.sample_rate, layout);
    encode_input.format = input.format;
    AudioSource::Frames {
        input: encode_input,
        frames,
    }
}

/// A frame-stream video source (shell push).
pub fn video_frames(frames: BoxStream<VideoFrame>) -> VideoSource {
    VideoSource::Frames(frames)
}

/// Bundled fallback: a decoded audio file (WAV/MP3/FLAC) as a capture source.
pub struct FileAudioCapture {
    input: moq_audio::encode::Input,
    frames: BoxStream<AudioFrame>,
}

impl FileAudioCapture {
    pub fn open(path: &Path, loop_playback: bool) -> anyhow::Result<Self> {
        let source = moq_media::audio_file::AudioFile::open(path, loop_playback)?;
        Ok(Self {
            input: source.input(),
            frames: source.into_stream(),
        })
    }
}

impl AudioCapture for FileAudioCapture {
    fn into_source(self: Box<Self>) -> AudioSource {
        AudioSource::Frames {
            input: self.input,
            frames: self.frames,
        }
    }
}

/// Bundled fallback: pre-encoded Annex-B H.264 as a capture source.
pub struct FileVideoCapture {
    source: VideoSource,
}

impl FileVideoCapture {
    pub fn annexb(path: &Path) -> anyhow::Result<Self> {
        let data = std::fs::read(path)
            .map_err(|err| anyhow::anyhow!("cannot read {}: {err}", path.display()))?;
        if !data.windows(4).any(|w| w == [0, 0, 0, 1]) {
            anyhow::bail!("video source must be Annex-B H.264 or a supported container");
        }
        let stream: BoxStream<bytes::Bytes> =
            Box::pin(n0_future::stream::iter([bytes::Bytes::from(data)]));
        Ok(Self {
            source: VideoSource::AnnexB(stream),
        })
    }
}

impl VideoCapture for FileVideoCapture {
    fn into_source(self: Box<Self>) -> VideoSource {
        self.source
    }
}

/// Bundled fallback: the platform default microphone via device capture.
pub struct DeviceAudioCapture {
    device: Option<String>,
}

impl DeviceAudioCapture {
    pub fn new(device: Option<String>) -> Self {
        Self { device }
    }
}

impl AudioCapture for DeviceAudioCapture {
    fn into_source(self: Box<Self>) -> AudioSource {
        let mut config = moq_audio::capture::Config::default();
        config.source = moq_audio::capture::Source::Microphone(self.device);
        AudioSource::Device(config)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn annexb_capture_is_a_video_source() {
        let dir = std::env::temp_dir().join("idfon-seam-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("clip.h264");
        std::fs::write(&path, [0u8, 0, 0, 1, 0x67, 0x42]).unwrap();
        let capture = FileVideoCapture::annexb(&path).unwrap();
        assert!(matches!(
            Box::new(capture).into_source(),
            VideoSource::AnnexB(_)
        ));
    }

    #[test]
    fn rejects_non_annexb() {
        let dir = std::env::temp_dir().join("idfon-seam-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nope.bin");
        std::fs::write(&path, b"not video").unwrap();
        assert!(FileVideoCapture::annexb(&path).is_err());
    }

    fn f32_mono() -> AudioInput {
        AudioInput {
            format: Format::F32,
            sample_rate: 48_000,
            channels: 1,
        }
    }

    #[test]
    fn paced_playback_drains_in_order_with_lead() {
        let emitted = Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink_out = emitted.clone();
        let mut sink = PacedPlayback::new(
            f32_mono(),
            Box::new(move |data| sink_out.lock().unwrap().extend_from_slice(data)),
        );
        // 200 ms of f32 mono @ 48 kHz, in one burst.
        let pcm = vec![7u8; 38_400];
        sink.write(&pcm, 0).unwrap();
        // The burst must park as lead, not play at once.
        assert!(
            sink.buffered() >= Duration::from_millis(150),
            "buffered = {:?}",
            sink.buffered()
        );
        // Prebuffer 50 ms + 200 ms of paced emits.
        std::thread::sleep(Duration::from_millis(600));
        assert_eq!(*emitted.lock().unwrap(), pcm);
        assert!(
            sink.buffered() <= Duration::from_millis(20),
            "buffered = {:?}",
            sink.buffered()
        );
    }

    #[test]
    fn paced_playback_applies_volume() {
        let emitted = Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink_out = emitted.clone();
        let mut sink = PacedPlayback::new(
            f32_mono(),
            Box::new(move |data| sink_out.lock().unwrap().extend_from_slice(data)),
        );
        sink.set_volume(0.5);
        // 100 ms of 1.0 samples.
        let pcm: Vec<u8> = 1.0f32
            .to_le_bytes()
            .iter()
            .copied()
            .cycle()
            .take(38_400 / 2)
            .collect();
        sink.write(&pcm, 0).unwrap();
        std::thread::sleep(Duration::from_millis(600));
        let out = emitted.lock().unwrap();
        assert_eq!(out.len(), pcm.len());
        let first = f32::from_le_bytes(out[0..4].try_into().unwrap());
        assert_eq!(first, 0.5);
    }

    /// The prebuffer target tracks recent arrival jitter (docs/media-
    /// adaptation.md §C8): the default while warming up, the floor for
    /// perfect arrivals, following a jittery tail toward the ceiling.
    #[test]
    fn arrival_jitter_drives_the_paced_target() {
        let mut jitter = ArrivalJitter::new();
        let start = std::time::Instant::now();

        // Too few samples to judge: the default.
        for i in 0..4 {
            jitter.record(start + Duration::from_millis(i * 20), i * 20_000);
        }
        assert_eq!(jitter.target(), PLAYOUT_TARGET);

        // Writes without media spacing (pts 0 or a repeat) say nothing.
        jitter.record(start + Duration::from_millis(100), 0);
        assert_eq!(jitter.target(), PLAYOUT_TARGET);

        // Steady arrivals at exactly media rate: the floor.
        for i in 0..64u64 {
            jitter.record(start + Duration::from_millis(1_000 + i * 20), 1_000_000 + i * 20_000);
        }
        assert_eq!(jitter.target(), PLAYOUT_TARGET_MIN);

        // Every other write slips 60 ms against the media clock: the p95
        // lands on the slip.
        for i in 0..64u64 {
            jitter.record(
                start + Duration::from_millis(2_000 + i * 20 + (i % 2) * 60),
                2_000_000 + i * 20_000,
            );
        }
        assert_eq!(jitter.target(), Duration::from_millis(60));

        // Slips past the ceiling clamp at the ceiling.
        for i in 0..64u64 {
            jitter.record(
                start + Duration::from_millis(3_000 + i * 20 + (i % 2) * 200),
                3_000_000 + i * 20_000,
            );
        }
        assert_eq!(jitter.target(), PLAYOUT_TARGET_MAX);
    }
}