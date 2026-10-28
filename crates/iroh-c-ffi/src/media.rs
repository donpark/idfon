//! Current native media bridge built on the current iroh-live/moq-media APIs.
//!
//! The old iroh-live media backend was intentionally removed. Native shells push
//! frames/samples into the current source model; capture and decode ownership
//! stays in moq-audio/moq-video.

use std::{
    collections::VecDeque,
    ffi::c_void,
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, AtomicUsize, Ordering},
    sync::{Arc, Mutex},
};

use iroh::{endpoint::presets, protocol::Router, Endpoint};
use iroh_blobs::{store::fs::FsStore, ticket::BlobTicket, BlobsProtocol, ALPN as BLOBS_ALPN};
use iroh_live::{ticket::LiveTicket, Live};
use moq_audio::encode::{
    Codec as AudioCodec, Options as AudioOptions, Publication, PublicationOptions,
};
use moq_audio::{Format, Frame as AudioFrame};
use moq_media::publish::{AudioSource, LocalBroadcast, VideoRendition, VideoSource};
use moq_video::{Frame as VideoFrame, Size, Surface};
use n0_future::{boxed::BoxStream, stream::unfold};
use safer_ffi::prelude::*;

use idfon_media::seam::{
    audio_frames, video_frames, AudioCapture, AudioInput, AudioPlayback, DeviceAudioCapture,
    FileAudioCapture, PacedPlayback, VideoCapture,
};

use crate::util::tokio_executor;

const AUDIO_CAPACITY: usize = 48_000 * 2;
static AUDIO_QUEUE: Mutex<Option<Arc<Mutex<VecDeque<f32>>>>> = Mutex::new(None);
static AUDIO_QUEUE_RATE: AtomicUsize = AtomicUsize::new(48_000);
/// Interleaved channel count the live publisher was started with. Shell pushes
/// must match it: the encoder's PCM layout is fixed when the track is created.
static AUDIO_PUSH_CHANNELS: std::sync::atomic::AtomicU32 =
    std::sync::atomic::AtomicU32::new(1);
static AUDIO_SAMPLES_PUSHED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static AUDIO_SAMPLES_NONZERO: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static AUDIO_FRAMES_ENCODED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static AUDIO_FRAMES_DECODED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static AUDIO_QUEUE_UNDERRUN_SAMPLES: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);
static AUDIO_QUEUE_OVERFLOW_SAMPLES: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);
static LIVE: Mutex<Option<LiveSession>> = Mutex::new(None);
static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);
static MEDIA_SCOPE: Mutex<Option<PathBuf>> = Mutex::new(None);
static LIVE_CONFIG: Mutex<Option<(bool, bool, bool, Option<PathBuf>, AudioCodec, u32, u32)>> =
    Mutex::new(None);
static AUDIO_ENABLED: AtomicBool = AtomicBool::new(true);
static VIDEO_ENABLED: AtomicBool = AtomicBool::new(false);

/// Audio samples the playout could not deliver in time, for health checks.
pub(crate) fn underruns() -> u64 {
    AUDIO_QUEUE_UNDERRUN_SAMPLES.load(Ordering::Relaxed)
}

/// Whether the live session carries video, for health-check tips.
pub(crate) fn video_enabled() -> bool {
    VIDEO_ENABLED.load(Ordering::Relaxed)
}
static SUBSCRIBER: Mutex<Option<Subscriber>> = Mutex::new(None);
static RECORDING: Mutex<Option<Recording>> = Mutex::new(None);
static RECORDING_DURATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static BLOB_PROVIDER: Mutex<Option<BlobProvider>> = Mutex::new(None);
static VIDEO_QUEUE: Mutex<Option<(u32, u32, Vec<u8>, u64)>> = Mutex::new(None);
static VIDEO_FRAMES_PUSHED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static VIDEO_FRAMES_CONSUMED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static PLAYBACK: Mutex<Option<Playback>> = Mutex::new(None);
/// The looping call tone (donpark/idfon#15): its own playback thread so a
/// tone stop never disturbs a recording playback and vice versa.
static TONE: Mutex<Option<Playback>> = Mutex::new(None);
static PLAYBACK_CONTROL: Mutex<Option<moq_audio::playback::Control>> = Mutex::new(None);
static PLAYBACK_ENGINE: Mutex<Option<moq_audio::playback::Engine>> = Mutex::new(None);
static INPUT_DEVICE: Mutex<Option<String>> = Mutex::new(None);
static OUTPUT_DEVICE: Mutex<Option<String>> = Mutex::new(None);
static VOLUME: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(100);
static BITRATE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(36_000);

/// Stored as `usize` so the function pointer survives a static `Mutex`.
type AudioPlaybackFn = unsafe extern "C" fn(*const c_void, *const u8, usize, u32, u32, u64);

/// Optional shell-owned audio playback. When absent, decoded audio goes to the
/// bundled moq playback device; when set, the shell gets interleaved f32 PCM.
static AUDIO_PLAYBACK_CB: Mutex<Option<(usize, AudioPlaybackFn)>> = Mutex::new(None);

/// Register a shell audio renderer before `media_live_subscribe`.
///
/// The callback runs on the seam's pacing thread and is handed a borrowed
/// interleaved f32 PCM buffer valid only for the duration of the call; copy
/// before returning. Frames are paced through `seam::PacedPlayback`'s jitter
/// buffer, so `pts_us` is always 0 (in-order playout carries no per-frame
/// clock).
#[ffi_export]
pub fn media_audio_set_playback_cb(
    ctx: *const c_void,
    cb: unsafe extern "C" fn(*const c_void, *const u8, usize, u32, u32, u64),
) -> u8 {
    *AUDIO_PLAYBACK_CB.lock().unwrap() = Some((ctx as usize, cb));
    0
}

#[ffi_export]
pub fn media_audio_clear_playback_cb() {
    *AUDIO_PLAYBACK_CB.lock().unwrap() = None;
}

struct LiveSession {
    live: Live,
    _audio: Option<LocalBroadcast>,
    _video: Option<LocalBroadcast>,
}

struct Subscriber {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}
struct Recording {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}
struct BlobProvider {
    endpoint: Endpoint,
    store: FsStore,
    _router: Router,
}
struct Playback {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

pub(crate) fn media_base() -> PathBuf {
    std::env::var_os("IDFON_MEDIA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("idfon"))
}

pub(crate) fn media_path(name: &str) -> PathBuf {
    let root = MEDIA_SCOPE
        .lock()
        .ok()
        .and_then(|scope| scope.clone())
        .unwrap_or_else(media_base);
    root.join(name)
}

/// Resolve a caller-supplied scope to a directory. A bare conversation id is
/// not a path: `create_dir_all` on it would drop a directory into the process
/// cwd, so only an absolute scope is honored as-is and anything else is placed
/// under the media root.
fn scoped_media_dir(scope: &Path) -> PathBuf {
    let relative = scope.is_relative();
    if relative {
        let name = scope.file_name().unwrap_or_else(|| scope.as_os_str());
        media_base().join(name)
    } else {
        scope.to_path_buf()
    }
}

fn audio_queue() -> Arc<Mutex<VecDeque<f32>>> {
    let mut slot = AUDIO_QUEUE.lock().expect("audio queue poisoned");
    slot.get_or_insert_with(|| Arc::new(Mutex::new(VecDeque::with_capacity(AUDIO_CAPACITY))))
        .clone()
}

/// Largest single capture push seen, so the trim target fits the device.
static AUDIO_MAX_BURST: AtomicUsize = AtomicUsize::new(0);

fn audio_stream(
    queue: Arc<Mutex<VecDeque<f32>>>,
    sample_rate: u32,
    channels: u32,
) -> BoxStream<AudioFrame> {
    let frame_samples = sample_rate as usize / 50 * channels as usize;
    let mut ticker = tokio::time::interval_at(
        tokio::time::Instant::now() + std::time::Duration::from_millis(20),
        std::time::Duration::from_millis(20),
    );
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    Box::pin(unfold(
        (queue, 0u64, ticker, None::<std::time::Instant>),
        move |(queue, pts, mut ticker, last_tick)| async move {
            ticker.tick().await;
            let now = std::time::Instant::now();
            let tick_gap_us = last_tick
                .map(|last| now.duration_since(last).as_micros())
                .unwrap_or(20_000);
            let mut data = vec![0.0f32; frame_samples];
            let (missing, depth) = if AUDIO_ENABLED.load(Ordering::Relaxed) {
                let mut q = queue.lock().ok()?;
                let available = q.len().min(frame_samples);
                for sample in data.iter_mut() {
                    *sample = q.pop_front().unwrap_or(0.0);
                }
                (frame_samples - available, q.len())
            } else {
                if let Ok(mut q) = queue.lock() {
                    q.clear();
                }
                (0, 0)
            };
            if missing > 0 {
                AUDIO_QUEUE_UNDERRUN_SAMPLES.fetch_add(missing as u64, Ordering::Relaxed);
            }
            let encoded = AUDIO_FRAMES_ENCODED.fetch_add(1, Ordering::Relaxed) + 1;
            if encoded <= 3 || encoded % 50 == 0 || missing > 0 || tick_gap_us > 30_000 {
                eprintln!(
                    "[media] audio frame={} rate={} queue={} underflow={} samples tick_gap={}us",
                    encoded, sample_rate, depth, missing, tick_gap_us
                );
            }
            let bytes: Vec<u8> = data.into_iter().flat_map(f32::to_le_bytes).collect();
            let pts_delta = if tick_gap_us > 30_000 {
                tick_gap_us as u64
            } else {
                20_000
            };
            let timestamp = moq_net::Timestamp::from_micros(pts).ok()?;
            Some((
                AudioFrame::new(bytes::Bytes::from(bytes), timestamp),
                (queue, pts + pts_delta, ticker, Some(now)),
            ))
        },
    ))
}

fn video_stream() -> BoxStream<VideoFrame> {
    Box::pin(unfold((), |_| async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            if !VIDEO_ENABLED.load(Ordering::Relaxed) {
                continue;
            }
            let Some((width, height, pixels, pts)) = VIDEO_QUEUE.lock().ok()?.take() else {
                continue;
            };
            VIDEO_FRAMES_CONSUMED.fetch_add(1, Ordering::Relaxed);
            let size = Size { width, height };
            let surface = Surface::rgba(&pixels, size).ok()?;
            let timestamp = moq_net::Timestamp::from_micros(pts).ok()?;
            return Some((VideoFrame::new(surface, timestamp), ()));
        }
    }))
}

/// Platform capture adapter: PCM pushed by the shell via `media_audio_push_samples`.
struct ShellAudioCapture {
    sample_rate: u32,
    channels: u32,
}

impl AudioCapture for ShellAudioCapture {
    fn into_source(self: Box<Self>) -> AudioSource {
        audio_frames(
            AudioInput {
                format: Format::F32,
                sample_rate: self.sample_rate,
                channels: self.channels,
            },
            audio_stream(audio_queue(), self.sample_rate, self.channels),
        )
    }
}

/// Platform capture adapter: RGBA frames pushed by the shell via `media_video_push_frame`.
struct ShellVideoCapture;

impl VideoCapture for ShellVideoCapture {
    fn into_source(self: Box<Self>) -> VideoSource {
        video_frames(video_stream())
    }
}

/// Bundled fallback: decoded audio to the platform output device via moq.
struct DevicePlayback {
    engine: moq_audio::playback::Engine,
    sink: moq_audio::playback::Sink,
    control: moq_audio::playback::Control,
    input: AudioInput,
}

impl DevicePlayback {
    async fn open(device: Option<String>, input: AudioInput) -> anyhow::Result<Self> {
        let engine = moq_audio::playback::Engine::open({
            let mut config = moq_audio::playback::Config::default();
            config.device = device;
            config
        })
        .await
        .map_err(|err| anyhow::anyhow!("playback engine: {err}"))?;
        let mut spec = moq_audio::playback::Input::default();
        spec.format = input.format;
        spec.sample_rate = input.sample_rate;
        spec.channels = input.channels;
        let sink = engine
            .sink(spec)
            .map_err(|err| anyhow::anyhow!("playback sink: {err}"))?;
        let control = sink.control();
        Ok(Self {
            engine,
            sink,
            control,
            input,
        })
    }

    fn engine(&self) -> moq_audio::playback::Engine {
        self.engine.clone()
    }

    fn control(&self) -> moq_audio::playback::Control {
        self.control.clone()
    }
}

impl AudioPlayback for DevicePlayback {
    fn input(&self) -> AudioInput {
        self.input
    }

    fn write(&mut self, pcm: &[u8], _pts_us: u64) -> anyhow::Result<()> {
        self.sink
            .write(pcm)
            .map_err(|err| anyhow::anyhow!("playback write: {err}"))
    }

    fn buffered(&self) -> std::time::Duration {
        self.sink.buffered()
    }

    fn set_volume(&mut self, volume: f32) {
        self.control.set_volume(volume);
    }
}

fn start_live(
    audio: bool,
    video: bool,
    push_audio: bool,
    file_audio: Option<PathBuf>,
    codec: AudioCodec,
    sample_rate: u32,
    channels: u32,
) -> anyhow::Result<String> {
    anyhow::ensure!(
        (8_000..=48_000).contains(&sample_rate) && sample_rate % 50 == 0,
        "unsupported live audio sample rate: {sample_rate}"
    );
    anyhow::ensure!(
        (1..=2).contains(&channels),
        "unsupported live audio channel count: {channels}"
    );
    AUDIO_PUSH_CHANNELS.store(channels, Ordering::Relaxed);
    AUDIO_ENABLED.store(true, Ordering::Relaxed);
    AUDIO_QUEUE_RATE.store(sample_rate as usize, Ordering::Relaxed);
    AUDIO_QUEUE_UNDERRUN_SAMPLES.store(0, Ordering::Relaxed);
    AUDIO_QUEUE_OVERFLOW_SAMPLES.store(0, Ordering::Relaxed);
    AUDIO_SAMPLES_PUSHED.store(0, Ordering::Relaxed);
    AUDIO_SAMPLES_NONZERO.store(0, Ordering::Relaxed);
    AUDIO_FRAMES_ENCODED.store(0, Ordering::Relaxed);
    if push_audio {
        // Capture starts before the publisher so permission/device setup can
        // overlap network startup. Discard that startup backlog rather than
        // making the peer hear up to two seconds of stale audio.
        if let Ok(mut queue) = AUDIO_QUEUE.lock() {
            *queue = None;
        }
    }
    if !audio && !video {
        anyhow::bail!("at least one media track is required");
    }
    let result = tokio_executor(async move {
        let live = Live::from_env().await?.spawn();
        // Accept-side routing (MoQ + the health ALPN) comes from the health
        // module's router (docs/media-adaptation.md §B2.2).
        crate::health::ensure_served(&live);
        let name = format!("idfon-live-{}", std::process::id());
        let mut combined_broadcast = None;
        if audio || video {
            let broadcast = live.publish(&name)?;
            if audio {
                let mut options = AudioOptions::default();
                options.codec = codec;
                options.sample_rate = Some(sample_rate);
                // BITRATE is per channel: stereo speech wants ~64 kbps at the
                // 32 kbps default (music wants `media_audio_set_bitrate`).
                // With FEC, stereo needs a higher floor: at 36 kbps per channel
                // the LBRR copy pays for itself by coupling the channels,
                // audible as crosstalk (stereo_tone_roundtrip test).
                let per_channel = BITRATE
                    .load(Ordering::Relaxed)
                    .max(if codec == AudioCodec::Opus && channels > 1 { 48_000 } else { 0 });
                options.bitrate =
                    (codec == AudioCodec::Opus).then(|| per_channel as u32 * channels);
                // DTX: silence costs ~nothing on the wire; the decode side honors it.
                options.dtx = codec == AudioCodec::Opus;
                // In-band FEC: the frame after a hole carries a copy of this
                // one. LBRR is paid from inside the budget, hence the bitrate
                // step above (docs/media-adaptation.md §D7).
                // FEC only for mono voice: the measured recovery win is
                // speech (docs/media-adaptation.md §D7). On stereo the LBRR
                // copy is paid in bandwidth (decide_fec: above a 5% loss hint
                // it narrows bandwidth to fit FEC), and that pushes the
                // encoder into coupled coding: the channels leak into each
                // other. Stereo calls trade resilience for the stereo image.
                options.fec = codec == AudioCodec::Opus && channels == 1;
                // Capture device is the default live source; shell-pushed PCM
                // remains available through `media_audio_push_samples`.
                let capture: Box<dyn AudioCapture> = if push_audio {
                    Box::new(ShellAudioCapture {
                        sample_rate,
                        channels,
                    })
                } else if let Some(path) = file_audio {
                    Box::new(FileAudioCapture::open(&path, false)?)
                } else {
                    Box::new(DeviceAudioCapture::new(
                        INPUT_DEVICE.lock().unwrap().clone(),
                    ))
                };
                broadcast.audio().set_with(capture.into_source(), options);
            }
            if video {
                VIDEO_ENABLED.store(true, Ordering::Relaxed);
                broadcast.video().set_renditions(
                    Box::new(ShellVideoCapture).into_source(),
                    vec![VideoRendition::new("video")],
                )?;
            }
            combined_broadcast = Some(broadcast);
        }
        let ticket = LiveTicket::new(live.endpoint().id(), &name).serialize();
        LIVE.lock()
            .expect("live mutex poisoned")
            .replace(LiveSession {
                live,
                _audio: combined_broadcast,
                _video: None,
            });
        anyhow::Ok(ticket)
    });
    match result {
        Ok(ticket) => {
            *LAST_ERROR.lock().expect("error poisoned") = None;
            Ok(ticket)
        }
        Err(err) => {
            *LAST_ERROR.lock().expect("error poisoned") = Some(format!("{err:#}"));
            Err(err)
        }
    }
}

#[ffi_export]
pub fn media_live_start(audio: u8, video: u8) -> char_p::Box {
    media_live_start_inner(
        audio != 0,
        video != 0,
        false,
        None,
        AudioCodec::Opus,
        48_000,
        1,
    )
}

fn media_live_start_inner(
    audio: bool,
    video: bool,
    push_audio: bool,
    file_audio: Option<PathBuf>,
    codec: AudioCodec,
    sample_rate: u32,
    channels: u32,
) -> char_p::Box {
    match start_live(
        audio,
        video,
        push_audio,
        file_audio.clone(),
        codec,
        sample_rate,
        channels,
    ) {
        Ok(ticket) => {
            *LIVE_CONFIG.lock().unwrap() =
                Some((audio, video, push_audio, file_audio, codec, sample_rate, channels));
            ticket.try_into().unwrap()
        }
        Err(_) => String::new().try_into().unwrap(),
    }
}

#[ffi_export]
pub fn media_live_start_with_source(audio: u8, video: u8, source: char_p::Ref<'_>) -> char_p::Box {
    let source = source.to_str();
    let file = source
        .strip_prefix("file:")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from);
    if source != "mic" && source != "push" && file.is_none() {
        *LAST_ERROR.lock().unwrap() = Some(format!("unknown live source: {source}"));
        return String::new().try_into().unwrap();
    }
    media_live_start_inner(
        audio != 0,
        video != 0,
        source == "push",
        file,
        AudioCodec::Opus,
        48_000,
        1,
    )
}

fn supported_audio_profile(codec: AudioCodec, sample_rate: u32) -> bool {
    matches!(
        (codec, sample_rate),
        (AudioCodec::Opus, 48_000) | (AudioCodec::Pcm, 24_000)
    )
}

#[ffi_export]
pub fn media_live_start_with_profile(
    audio: u8,
    video: u8,
    source: char_p::Ref<'_>,
    codec: char_p::Ref<'_>,
    sample_rate: u32,
    channels: u32,
) -> char_p::Box {
    let codec = match codec.to_str() {
        "opus" => AudioCodec::Opus,
        "pcm" => AudioCodec::Pcm,
        other => {
            *LAST_ERROR.lock().unwrap() = Some(format!("unknown live audio codec: {other}"));
            return String::new().try_into().unwrap();
        }
    };
    if !supported_audio_profile(codec, sample_rate) {
        *LAST_ERROR.lock().unwrap() = Some(format!(
            "unsupported live audio profile: {codec} at {sample_rate} Hz"
        ));
        return String::new().try_into().unwrap();
    }
    if channels != 1 && channels != 2 {
        *LAST_ERROR.lock().unwrap() =
            Some(format!("unsupported live audio channel count: {channels}"));
        return String::new().try_into().unwrap();
    }
    if codec == AudioCodec::Pcm && channels != 1 {
        *LAST_ERROR.lock().unwrap() = Some("pcm24k voice-agent calls are mono".into());
        return String::new().try_into().unwrap();
    }
    let source = source.to_str();
    let file = source
        .strip_prefix("file:")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from);
    if source != "mic" && source != "push" && file.is_none() {
        *LAST_ERROR.lock().unwrap() = Some(format!("unknown live source: {source}"));
        return String::new().try_into().unwrap();
    }
    media_live_start_inner(
        audio != 0,
        video != 0,
        source == "push",
        file,
        codec,
        sample_rate,
        channels,
    )
}

#[ffi_export]
pub fn media_audio_push_samples(pcm: *const f32, samples: usize) {
    media_audio_push_frames(pcm, samples, 1)
}

/// Stereo-aware push: `frames` frames of `channels` interleaved f32 samples.
/// The channel count must match the live publisher's
/// (`media_live_start_with_profile`); mismatched pushes are dropped so a mono
/// meter cannot corrupt a stereo call's channel alignment.
#[ffi_export]
pub fn media_audio_push_frames(pcm: *const f32, frames: usize, channels: u32) {
    if pcm.is_null() || frames == 0 {
        return;
    }
    let expected = AUDIO_PUSH_CHANNELS.load(Ordering::Relaxed);
    if channels != expected {
        eprintln!(
            "[media] audio push with {channels} channels dropped (publisher runs {expected})"
        );
        return;
    }
    let samples = frames * channels as usize;
    let rate = AUDIO_QUEUE_RATE.load(Ordering::Relaxed) as u64;
    let pushed = AUDIO_SAMPLES_PUSHED.fetch_add(samples as u64, Ordering::Relaxed) + samples as u64;
    if pushed <= 2_000 || pushed % rate < samples as u64 {
        eprintln!(
            "[media] audio samples pushed total={} rate={}",
            pushed, rate
        );
    }
    let input = unsafe { std::slice::from_raw_parts(pcm, samples) };
    let nonzero = input.iter().filter(|sample| sample.abs() > 0.0001).count() as u64;
    AUDIO_SAMPLES_NONZERO.fetch_add(nonzero, Ordering::Relaxed);
    if pushed <= 2_000 || pushed % rate < samples as u64 {
        let peak = input
            .iter()
            .fold(0.0f32, |peak, sample| peak.max(sample.abs()));
        let rms = (input.iter().map(|sample| sample * sample).sum::<f32>() / samples as f32).sqrt();
        eprintln!(
            "[media] pushed audio samples={} nonzero={} rms={:.5} peak={:.5}",
            samples, nonzero, rms, peak
        );
    }
    let queue = audio_queue();
    let result = queue.lock();
    if let Ok(mut q) = result {
        q.extend(input.iter().copied());
        // Trim here, on the capture callback: this runs in real time even when
        // the encoder pump is starved by network backpressure, so backlog
        // cannot ratchet up to the queue capacity while the pump is blocked.
        // (Queue depth IS latency: capture pushes at the selected sample rate.)
        let burst = AUDIO_MAX_BURST
            .fetch_max(samples, Ordering::Relaxed)
            .max(samples);
        let target = (burst * 2).max(rate as usize * 40 / 1_000);
        let excess = q.len().saturating_sub(target);
        // Trim whole frames only: one stray sample dropped from an interleaved
        // stream swaps the channels of every later sample on stereo.
        let channels = AUDIO_PUSH_CHANNELS.load(Ordering::Relaxed).max(1) as usize;
        let excess = excess - excess % channels;
        if excess > 0 {
            AUDIO_QUEUE_OVERFLOW_SAMPLES.fetch_add(excess as u64, Ordering::Relaxed);
            for _ in 0..excess {
                q.pop_front();
            }
        }
    }
}

#[ffi_export]
pub fn media_live_set_audio_enabled(enabled: u8) -> u8 {
    AUDIO_ENABLED.store(enabled != 0, Ordering::Relaxed);
    0
}
#[ffi_export]
pub fn media_live_set_video_enabled(enabled: u8) -> u8 {
    VIDEO_ENABLED.store(enabled != 0, Ordering::Relaxed);
    // Drop the frame parked while the camera was on: re-enabling would
    // otherwise encode it with a timestamp behind everything already sent.
    if enabled == 0 {
        if let Ok(mut slot) = VIDEO_QUEUE.lock() {
            *slot = None;
        }
    }
    eprintln!(
        "[media] video enabled={} pushed={} consumed={}",
        enabled,
        VIDEO_FRAMES_PUSHED.load(Ordering::Relaxed),
        VIDEO_FRAMES_CONSUMED.load(Ordering::Relaxed)
    );
    0
}
#[ffi_export]
pub fn media_live_last_error() -> char_p::Box {
    LAST_ERROR
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_default()
        .try_into()
        .unwrap()
}
#[ffi_export]
pub fn media_live_stop() {
    VIDEO_ENABLED.store(false, Ordering::Relaxed);
    let underruns = AUDIO_QUEUE_UNDERRUN_SAMPLES.swap(0, Ordering::Relaxed);
    let overflows = AUDIO_QUEUE_OVERFLOW_SAMPLES.swap(0, Ordering::Relaxed);
    if underruns > 0 || overflows > 0 {
        eprintln!(
            "[media] audio queue gaps: underrun_samples={} overflow_samples={}",
            underruns, overflows
        );
    }
    if let Some(session) = LIVE.lock().unwrap().take() {
        tokio_executor(session.live.shutdown());
    }
    *LIVE_CONFIG.lock().unwrap() = None;
    if let Ok(mut frame) = VIDEO_QUEUE.lock() {
        *frame = None;
    }
    if let Ok(mut queue) = AUDIO_QUEUE.lock() {
        *queue = None;
    }
}
#[ffi_export]
pub fn media_live_subscribe(ticket: char_p::Ref<'_>) -> u8 {
    media_live_unsubscribe();
    let Ok(ticket) = ticket.to_str().parse::<LiveTicket>() else {
        return 1;
    };
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let handle = std::thread::spawn(move || {
        let Ok(runtime) = tokio::runtime::Runtime::new() else {
            return;
        };
        let result = runtime.block_on(async move {
            // Attempt loop: the subscriber sometimes sees the remote track end
            // mid-call (observed on iOS ~20s in: mux consumer returned Ok(None)
            // while the holder kept publishing — suspected relay/route boundary).
            // A silent early end means dead air until hangup; treat it as
            // transient and re-subscribe while the call is still active.
            let mut samples: Vec<f32> = Vec::new();
            let mut decoded_channels = 1u32;
            let mut timing = String::from("frame,arrival_us,arrival_gap_us,pts_us,media_gap_us,samples,sink_buffered_ms\n");
            let mut decoded_total = 0usize;
            let capture_started = std::time::Instant::now();
            let mut attempt = 0u32;
            let result;
            loop {
                if thread_stop.load(Ordering::Relaxed) {
                    result = Ok(());
                    break;
                }
                attempt += 1;
                let res = subscribe_decode_once(
                    ticket.clone(),
                    &thread_stop,
                    &mut samples,
                    &mut timing,
                    &mut decoded_total,
                    capture_started,
                    attempt,
                    &mut decoded_channels,
                )
                .await;
                match res {
                    Ok(_ended_by_stop) => {
                        result = Ok(());
                        break;
                    }
                    Err(e) if e.downcast_ref::<SubscribeEndError>().is_some() => {
                        // The publisher sends continuous frames for the whole
                        // call, so an early track end is transient. Keep
                        // re-subscribing while the call is active: giving up
                        // after a fixed number of attempts left the rest of
                        // the call silent (heard as "on and off").
                        let backoff = std::time::Duration::from_millis(
                            (100u64 << attempt.min(4)).min(1_000),
                        );
                        eprintln!(
                            "[media] subscribe ended early attempt={attempt} decoded={decoded_total} frames; resubscribing in {}ms",
                            backoff.as_millis()
                        );
                        tokio::time::sleep(backoff).await;
                    }
                    Err(err) => {
                        result = Err(err);
                        break;
                    }
                }
            }
            let received_wav = media_path("received.wav");
            let received_timing = media_path("received-timing.csv");
            write_wav(&received_wav, &samples, decoded_channels)?;
            std::fs::write(&received_timing, timing)?;
            eprintln!("[media] live audio captures wav={} timing={}", received_wav.display(), received_timing.display());
            PLAYBACK_CONTROL.lock().unwrap().take();
            result
        });
        if let Err(err) = result {
            tracing::error!("live subscribe failed: {err:#}");
            eprintln!("live subscribe failed: {err:#}");
        }
    });
    *SUBSCRIBER.lock().unwrap() = Some(Subscriber {
        stop,
        handle: Some(handle),
    });
    0
}

/// Why one subscribe attempt ended.
#[derive(Debug)]
enum SubscribeEndError {
    #[allow(dead_code)]
    ByStop,
    Transient,
}

impl std::fmt::Display for SubscribeEndError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ByStop => write!(f, "stopped by caller"),
            Self::Transient => write!(f, "track ended early (transient)"),
        }
    }
}

impl std::error::Error for SubscribeEndError {}

/// Phone-side makeup gain for live-call playback.
///
/// Historically this compensated for `.playAndRecord` + `.voiceChat` routing
/// playback through VoiceProcessingIO, which drops output gain with no public
/// API to adjust it (StackOverflow 17528057 / 13502293); the 2026-09-25 device
/// fix measured +12 dB (docs/troubleshooting.md, "iOS live-call audio too
/// quiet"). Playback now renders on the shells' AVAudioEngine bus at normal
/// level (verified 2026-10-07), so the default is unity. Keep the knob for
/// devices/paths that still end up quiet: override with `IDFON_PLAYBACK_GAIN_DB`.
const PLAYBACK_GAIN_DB_DEFAULT: f32 = 0.0;

fn playback_gain() -> f32 {
    // VoiceProcessingIO's output drop is iOS-only; leave other platforms at
    // unity (macOS has the media volume slider to compensate).
    if !cfg!(target_os = "ios") {
        return 1.0;
    }
    static GAIN: std::sync::OnceLock<f32> = std::sync::OnceLock::new();
    *GAIN.get_or_init(|| {
        let db = std::env::var("IDFON_PLAYBACK_GAIN_DB")
            .ok()
            .and_then(|value| value.trim().parse::<f32>().ok())
            .filter(|value| value.is_finite())
            .unwrap_or(PLAYBACK_GAIN_DB_DEFAULT);
        10f32.powf(db / 20.0)
    })
}

/// Apply [`playback_gain`] to interleaved f32 PCM bytes, soft-clipping with
/// `tanh`. Returns the input unchanged at unity gain.
fn apply_playback_gain(data: &[u8]) -> Vec<u8> {
    let gain = playback_gain();
    if gain == 1.0 {
        return data.to_vec();
    }
    let mut out = Vec::with_capacity(data.len());
    for chunk in data.chunks_exact(4) {
        let sample = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        out.extend_from_slice(&(sample * gain).tanh().to_le_bytes());
    }
    out
}

/// One subscribe-and-decode attempt: connect, wait for the audio catalog,
/// decode into `samples`/`timing` until the track ends or `stop` is set.
/// Returns Ok(true) when the stop flag ended it, Ok(false) on an early track
/// end (caller decides whether to retry), Err on transport/setup failure.
async fn subscribe_decode_once(
    ticket: LiveTicket,
    stop: &std::sync::Arc<std::sync::atomic::AtomicBool>,
    samples: &mut Vec<f32>,
    timing: &mut String,
    decoded_total: &mut usize,
    capture_started: std::time::Instant,
    attempt: u32,
    channels_out: &mut u32,
) -> anyhow::Result<bool> {
    let live = Live::from_env().await?.spawn();
    // The subscriber owns nothing across attempts except the accumulators; a
    // fresh Live per attempt avoids reusing a possibly-torn-down endpoint.
    let res = async {
        let subscription = live
            .subscribe(ticket.endpoint, &ticket.broadcast_name)
            .await?;
        let broadcast = subscription.broadcast();
        // Health checks sample this session's downlink (docs/media-adaptation.md §B2.2).
        crate::health::attach(&live, subscription.signals().clone());
        // The publisher writes an empty catalog first and adds the audio
        // rendition once its encoder is probed, so the first snapshot a
        // fast subscriber sees may not carry it yet: wait for it.
        while !broadcast.has_audio() {
            if stop.load(Ordering::Relaxed) {
                return Ok(true);
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        let catalog = broadcast.catalog();
        let Some(name) = catalog.first_audio() else {
            anyhow::bail!("broadcast has no audio track");
        };
        let config = catalog
            .audio()
            .get(name)
            .ok_or_else(|| anyhow::anyhow!("audio catalog missing"))?;
        let mut decode = moq_audio::decode::Config::new();
        decode.format = Format::F32;
        decode.sample_rate = Some(48_000);
        // Native channel count from the catalog (mono or stereo): the shell
        // renders stereo natively — old mono publishers decode as mono.
        decode.channels = None;
        // Keep a bounded playout budget so a late group is not discarded
        // immediately. This is the decoder's jitter tolerance; the sink
        // below adds its own ~50 ms device buffer.
        decode.latency_max = Some(std::time::Duration::from_millis(50));
        // Live playout fills small holes from the next packet's in-band copy
        // (moq-audio `conceal`); recordings must show holes as-is.
        decode.conceal = std::time::Duration::from_millis(120);
        let mut consumer =
            moq_audio::decode::Consumer::new(broadcast.consumer(), config, name, decode).await?;
        let input = AudioInput {
            format: Format::F32,
            sample_rate: 48_000,
            channels: consumer.channels(),
        };
        *channels_out = input.channels;
        crate::health::set_channels(input.channels as u64);
        // Shell playback renders remote call audio on the app's playback bus,
        // which is the VoiceProcessingIO echo reference (docs/audio-media.md);
        // the bundled device engine is the fallback when no callback is set.
        let mut playback: Box<dyn AudioPlayback> = match *AUDIO_PLAYBACK_CB.lock().unwrap() {
            Some((ctx, cb)) => Box::new(PacedPlayback::new(input, Box::new(move |pcm| {
                // SAFETY: the shell copies before returning (documented contract).
                unsafe {
                    (cb)(
                        ctx as *const c_void,
                        pcm.as_ptr(),
                        pcm.len(),
                        input.sample_rate,
                        input.channels,
                        0,
                    )
                }
            }))),
            None => {
                let device = OUTPUT_DEVICE.lock().unwrap().clone();
                let device_playback = DevicePlayback::open(device, input).await?;
                PLAYBACK_ENGINE
                    .lock()
                    .unwrap()
                    .replace(device_playback.engine());
                let control = device_playback.control();
                control.set_volume(VOLUME.load(Ordering::Relaxed) as f32 / 100.0);
                *PLAYBACK_CONTROL.lock().unwrap() = Some(control);
                Box::new(device_playback)
            }
        };
        // A/V sync: video presents against the audio playout clock (av.rs).
        crate::av::reset();
        // Do not start the speaker on the first arriving packet. A short
        // startup prebuffer absorbs normal network/decoder scheduling
        // jitter without turning the first late packet into a click.
        const STARTUP_PREBUFFER_FRAMES: usize = 2_400; // 50 ms @ 48 kHz
        let mut startup = Vec::new();
        let mut started = false;
        let mut last_arrival = None;
        let mut expected_pts_us: Option<u128> = None;
        // The holder publishes continuous frames (silence on underflow), so a
        // multi-second frame gap while the call is active means the
        // subscription stalled (observed on iOS: the publisher's serve stream
        // died without SUBSCRIBE_END, and consumer.read() then never returns
        // — neither frames nor a track end). Treat it like an early end.
        const FRAME_STALL: std::time::Duration = std::time::Duration::from_secs(2);
        let mut last_frame = std::time::Instant::now();
        loop {
            if stop.load(Ordering::Relaxed) {
                if !started && !startup.is_empty() {
                    let _ = playback.write(&apply_playback_gain(&startup), 0);
                }
                return Ok(true);
            }
            if last_frame.elapsed() >= FRAME_STALL {
                tracing::warn!(
                    attempt,
                    decoded = *decoded_total,
                    media_secs = samples.len() as f64 / (48_000.0 * input.channels as f64),
                    stall_secs = last_frame.elapsed().as_secs_f64(),
                    "subscribe stalled: no frames for 2s; treating as early track end"
                );
                return Err(anyhow::anyhow!(SubscribeEndError::Transient));
            }
            let frame = match tokio::time::timeout(
                std::time::Duration::from_millis(200),
                consumer.read(),
            )
            .await
            {
                Ok(frame) => frame?,
                Err(_) => continue,
            };
            let Some(frame) = frame else {
                // Track ended. Normal only if the caller stopped it; otherwise
                // the holder is still publishing and this is a transient break.
                let media_secs = samples.len() as f64 / (48_000.0 * input.channels as f64);
                tracing::warn!(
                    attempt,
                    decoded = decoded_total,
                    media_secs,
                    wall_secs = capture_started.elapsed().as_secs_f64(),
                    "subscribe track ended early"
                );
                return Err(anyhow::anyhow!(SubscribeEndError::Transient));
            };
            last_frame = std::time::Instant::now();
            let decoded = AUDIO_FRAMES_DECODED.fetch_add(1, Ordering::Relaxed) + 1;
            *decoded_total = decoded as usize;
            let arrived = std::time::Instant::now();
            let arrival_us = capture_started.elapsed().as_micros();
            let arrival_gap_us = last_arrival
                .map(|last: std::time::Instant| arrived.duration_since(last).as_micros())
                .unwrap_or(0);
            let pts_us = frame.timestamp.as_micros();
            let media_gap_us =
                expected_pts_us.map(|expected| pts_us.saturating_sub(expected)).unwrap_or(0);
            let frame_samples = frame.data.len() / 4;
            expected_pts_us = Some(pts_us + frame_pts_gap_us(frame.data.as_ref(), input.channels));
            last_arrival = Some(arrived);
            if decoded <= 3 || decoded % 100 == 0 || arrival_gap_us > 30_000 || media_gap_us > 1_000 {
                eprintln!("[media] audio frame decoded #{} arrival_gap={}us media_gap={}us samples={}", decoded, arrival_gap_us, media_gap_us, frame_samples);
            }
            timing.push_str(&format!("{decoded},{arrival_us},{arrival_gap_us},{pts_us},{media_gap_us},{frame_samples},{:.2}\n", playback.buffered().as_secs_f64() * 1_000.0));
            if !started {
                startup.extend_from_slice(&frame.data);
                if startup.len() / 4 < STARTUP_PREBUFFER_FRAMES * input.channels as usize {
                    continue;
                }
                let batch_us = (startup.len() as u128 / 4 / input.channels.max(1) as u128)
                    * 1_000_000
                    / input.sample_rate.max(1) as u128;
                playback.write(&apply_playback_gain(&startup), pts_us as u64)?;
                // The batch plays as one block starting at pts_us - batch_us.
                crate::av::anchor_audio(
                    pts_us.saturating_sub(batch_us) as u64,
                    playback.buffered(),
                );
                startup.clear();
                started = true;
            } else {
                // NetEq-style shrink: the sink parks ahead-writes and never
                // drains back on its own, so discard down to the playout
                // target instead of ratcheting delay after every stall.
                const SINK_TARGET_LATENCY: f64 = 0.08; // 80 ms
                let buffered = playback.buffered().as_secs_f64();
                let mut data = frame.data.as_ref();
                let mut trim_samples = 0usize;
                if buffered > SINK_TARGET_LATENCY && data.len() >= 4 {
                    // Drop whole frames only: a half frame would swap the
                    // channels of every later sample on a stereo call.
                    let mut excess_samples = (((buffered - SINK_TARGET_LATENCY)
                        * 48_000.0) as usize)
                        .min(data.len() / 4);
                    excess_samples -= excess_samples % input.channels as usize;
                    trim_samples = excess_samples;
                    data = &data[excess_samples * 4..];
                }
                // Anchored at the pts of what is actually written: trimmed
                // front samples moved the playout start later.
                let written_pts_us = pts_us
                    + (trim_samples as u128 / input.channels.max(1) as u128) * 1_000_000
                        / input.sample_rate.max(1) as u128;
                playback.write(&apply_playback_gain(data), pts_us as u64)?;
                crate::av::anchor_audio(written_pts_us as u64, playback.buffered());
            }
            for chunk in frame.data.chunks_exact(4) {
                samples.push(f32::from_le_bytes(chunk.try_into().unwrap()));
            }
        }
    };
    let out = res.await;
    live.shutdown().await;
    out
}

/// Expected pts gap in µs for one frame: f32 samples at 48 kHz over `channels`.
fn frame_pts_gap_us(data: &[u8], channels: u32) -> u128 {
    (data.len() / 4) as u128 * 1_000_000 / (48_000 * channels as u128)
}

fn write_wav(
    path: &std::path::Path,
    samples: &[f32],
    channels: u32,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(path.parent().unwrap_or(std::path::Path::new(".")))?;
    let mut bytes = Vec::with_capacity(44 + samples.len() * 2);
    let data_len = (samples.len() * 2) as u32;
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&(channels as u16).to_le_bytes());
    bytes.extend_from_slice(&48_000u32.to_le_bytes());
    bytes.extend_from_slice(&(48_000 * channels * 2).to_le_bytes());
    bytes.extend_from_slice(&((channels * 2) as u16).to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&data_len.to_le_bytes());
    for sample in samples {
        bytes.extend_from_slice(&((sample.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
    }
    std::fs::write(path, bytes)?;
    Ok(())
}

/// The layout a WAV header declares: playback must honor it instead of
/// assuming mono 48 kHz s16 (stereo memos and the shells' 16 kHz memos both
/// arrive through the same file). Chunk walk, so extra chunks (e.g. `fact`)
/// are skipped and `data` may precede `fmt `; a `data` length that overshoots
/// the buffer is clamped so truncated captures still play what they have.
struct WavFormat {
    sample_rate: u32,
    channels: u32,
    bits_per_sample: u16,
    data_offset: usize,
    data_len: usize,
}

fn wav_format(data: &[u8]) -> Option<WavFormat> {
    if data.len() < 44 || &data[0..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        return None;
    }
    let mut format: Option<(u32, u32, u16)> = None;
    let mut payload: Option<(usize, usize)> = None;
    let mut pos = 12;
    while pos + 8 <= data.len() {
        let id = &data[pos..pos + 4];
        let len = u32::from_le_bytes(data[pos + 4..pos + 8].try_into().ok()?) as usize;
        let body = pos + 8;
        if id == b"fmt " {
            if len < 16 || body + 16 > data.len() {
                return None;
            }
            format = Some((
                u32::from_le_bytes(data[body + 4..body + 8].try_into().ok()?),
                u16::from_le_bytes(data[body + 2..body + 4].try_into().ok()?) as u32,
                u16::from_le_bytes(data[body + 14..body + 16].try_into().ok()?),
            ));
        } else if id == b"data" {
            payload = Some((body, len.min(data.len() - body)));
        } else if body.checked_add(len)? > data.len() {
            return None;
        }
        pos = body.checked_add(len)? + (len & 1);
    }
    let (sample_rate, channels, bits_per_sample) = format?;
    let (data_offset, data_len) = payload?;
    Some(WavFormat {
        sample_rate,
        channels,
        bits_per_sample,
        data_offset,
        data_len,
    })
}

#[ffi_export]
pub fn media_live_unsubscribe() {
    media_recording_stop_playback();
    if let Some(mut sub) = SUBSCRIBER.lock().unwrap().take() {
        sub.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = sub.handle.take() {
            let _ = handle.join();
        }
    }
}
#[ffi_export]
pub fn media_video_push_frame(data: *const u8, len: usize, width: u32, height: u32, pts_ms: u64) {
    if data.is_null() || width == 0 || height == 0 || len < width as usize * height as usize * 4 {
        return;
    }
    let pixels =
        unsafe { std::slice::from_raw_parts(data, width as usize * height as usize * 4) }.to_vec();
    let count = VIDEO_FRAMES_PUSHED.fetch_add(1, Ordering::Relaxed) + 1;
    if count <= 3 || count % 150 == 0 {
        eprintln!(
            "[media] video frame pushed #{} {}x{} enabled={}",
            count,
            width,
            height,
            VIDEO_ENABLED.load(Ordering::Relaxed)
        );
    }
    if let Ok(mut slot) = VIDEO_QUEUE.lock() {
        *slot = Some((width, height, pixels, pts_ms * 1_000));
    }
}

#[ffi_export]
pub fn media_audio_start() -> u8 {
    AUDIO_ENABLED.store(true, Ordering::Relaxed);
    0
}
#[ffi_export]
pub fn media_audio_stop() {
    AUDIO_ENABLED.store(false, Ordering::Relaxed);
}
#[ffi_export]
pub fn media_audio_active() -> u8 {
    u8::from(
        LIVE.lock().unwrap().is_some()
            || RECORDING.lock().unwrap().is_some()
            || SUBSCRIBER.lock().unwrap().is_some()
            || PLAYBACK.lock().unwrap().is_some(),
    )
}
#[ffi_export]
pub fn media_audio_probe(_duration_ms: u64) -> usize {
    audio_queue()
        .lock()
        .map(|queue| queue.iter().filter(|sample| sample.abs() > 0.001).count())
        .unwrap_or(0)
}
#[ffi_export]
pub fn media_audio_input_count() -> usize {
    tokio_executor(async {
        moq_audio::capture::devices()
            .await
            .map(|devices| devices.len())
            .unwrap_or(0)
    })
}
#[ffi_export]
pub fn media_audio_output_count() -> usize {
    tokio_executor(async {
        moq_audio::playback::devices()
            .await
            .map(|devices| devices.len())
            .unwrap_or(0)
    })
}
#[ffi_export]
pub fn media_audio_set_volume(percent: u8) -> u8 {
    let value = percent.min(100);
    VOLUME.store(value, Ordering::Relaxed);
    if let Some(control) = PLAYBACK_CONTROL.lock().unwrap().as_ref() {
        control.set_volume(value as f32 / 100.0);
    }
    0
}
#[ffi_export]
pub fn media_audio_switch_input(device: char_p::Ref<'_>) -> u8 {
    let id = device.to_str().to_owned();
    let found = tokio_executor(async {
        moq_audio::capture::devices()
            .await
            .map(|devices| devices.into_iter().any(|item| item.id == id))
            .unwrap_or(false)
    });
    if !found {
        return 1;
    }
    *INPUT_DEVICE.lock().unwrap() = Some(id);
    let config = LIVE_CONFIG.lock().unwrap().clone();
    if let Some((audio, video, push, file, codec, sample_rate, channels)) = config {
        media_live_stop();
        if start_live(audio, video, push, file.clone(), codec, sample_rate, channels).is_ok() {
            *LIVE_CONFIG.lock().unwrap() =
                Some((audio, video, push, file, codec, sample_rate, channels));
        }
    }
    0
}
#[ffi_export]
pub fn media_audio_switch_output(device: char_p::Ref<'_>) -> u8 {
    let id = device.to_str().to_owned();
    let found = tokio_executor(async {
        moq_audio::playback::devices()
            .await
            .map(|devices| devices.into_iter().any(|item| item.id == id))
            .unwrap_or(false)
    });
    if !found {
        return 1;
    }
    *OUTPUT_DEVICE.lock().unwrap() = Some(id.clone());
    if let Some(engine) = PLAYBACK_ENGINE.lock().unwrap().as_ref() {
        let mut config = moq_audio::playback::Config::default();
        config.device = Some(id);
        if tokio_executor(engine.switch(config)).is_err() {
            return 1;
        }
    }
    0
}
#[ffi_export]
pub fn media_audio_set_bitrate(bitrate: u32) -> u8 {
    if !(8_000..=510_000).contains(&bitrate) {
        return 1;
    }
    BITRATE.store(bitrate as u64, Ordering::Relaxed);
    0
}

/// Flip in-band FEC on the live audio track (docs/media-adaptation.md §B2.4).
///
/// The degradation ladder's stereo step calls this: stereo on is quality
/// mode (FEC off, the LBRR copy would couple the channels), auto stereo-off
/// is resilience mode (FEC on, the measured recovery win is mono speech).
/// Replacing the track restarts the encoder, which the stereo step's channel
/// change costs anyway. Returns 0 on success, 1 without a live audio track.
#[ffi_export]
pub fn media_audio_set_fec(fec: u8) -> u8 {
    let setup = LIVE_CONFIG.lock().unwrap().clone();
    let live = LIVE.lock().unwrap();
    let (Some(session), Some((audio, _video, push_audio, file_audio, codec, sample_rate, channels))) =
        (live.as_ref(), setup)
    else {
        return 1;
    };
    if !audio {
        return 1;
    }
    let Some(broadcast) = session._audio.as_ref() else {
        return 1;
    };
    // Mirror start_live's options; only the fec flag moves.
    let mut options = AudioOptions::default();
    options.codec = codec;
    options.sample_rate = Some(sample_rate);
    let per_channel = BITRATE
        .load(Ordering::Relaxed)
        .max(if codec == AudioCodec::Opus && channels > 1 {
            48_000
        } else {
            0
        });
    options.bitrate = (codec == AudioCodec::Opus).then(|| per_channel as u32 * channels);
    options.dtx = codec == AudioCodec::Opus;
    options.fec = codec == AudioCodec::Opus && fec != 0;
    // The shell queue is shared across replaces, so a push source keeps
    // whatever it holds; a device source re-opens.
    let capture: Box<dyn AudioCapture> = if push_audio {
        Box::new(ShellAudioCapture {
            sample_rate,
            channels,
        })
    } else if let Some(path) = file_audio {
        match FileAudioCapture::open(&path, false) {
            Ok(capture) => Box::new(capture),
            Err(_) => return 1,
        }
    } else {
        Box::new(DeviceAudioCapture::new(
            INPUT_DEVICE.lock().unwrap().clone(),
        ))
    };
    broadcast.audio().set_with(capture.into_source(), options);
    0
}
#[ffi_export]
pub fn media_recording_start() -> u8 {
    media_recording_stop();
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let handle = std::thread::spawn(move || {
        let result = tokio_executor(async move {
            let live = Live::from_env().await?.with_router().spawn();
            let path = format!("idfon-recording-{}", std::process::id());
            let mut producer = live.publish_raw(&path)?;
            let catalog = moq_mux::catalog::Producer::new(&mut producer)?;
            let mut options = PublicationOptions::default();
            options.capture.source =
                moq_audio::capture::Source::Microphone(INPUT_DEVICE.lock().unwrap().clone());
            options.encode.codec = moq_audio::encode::Codec::Opus;
            let (publication, driver) = Publication::new(producer, catalog, options)?;
            let mut driver_future = Box::pin(driver.run());
            let subscription_future = live.subscribe(live.endpoint().addr(), &path);
            tokio::pin!(subscription_future);
            let subscription = tokio::select! {
                result = &mut subscription_future => result?,
                result = &mut driver_future => {
                    result?;
                    anyhow::bail!("recording capture ended before subscription")
                }
            };
            let broadcast = subscription.broadcast();
            let catalog = broadcast.catalog();
            let name = catalog
                .first_audio()
                .ok_or_else(|| anyhow::anyhow!("recording audio track unavailable"))?
                .to_owned();
            let config = catalog
                .audio()
                .get(&name)
                .ok_or_else(|| anyhow::anyhow!("recording catalog unavailable"))?
                .clone();
            let mut decode = moq_audio::decode::Config::new();
            decode.format = Format::F32;
            decode.sample_rate = Some(48_000);
            decode.channels = None; // catalog count: 2ch when the mic is
            let mut consumer =
                moq_audio::decode::Consumer::new(broadcast.consumer(), &config, &name, decode)
                    .await?;
            let channels = consumer.channels();
            let mut samples = Vec::new();
            let started = std::time::Instant::now();
            loop {
                tokio::select! {
                    _ = &mut driver_future => break,
                    frame = consumer.read() => {
                        let Some(frame) = frame? else { break; };
                        if thread_stop.load(Ordering::Relaxed) { break; }
                        for chunk in frame.data.chunks_exact(4) { samples.push(f32::from_le_bytes(chunk.try_into().unwrap())); }
                    }
                }
            }
            write_wav(&media_path("recording.wav"), &samples, channels)?;
            RECORDING_DURATION.store(started.elapsed().as_millis() as u64, Ordering::Relaxed);
            drop(publication);
            live.shutdown().await;
            anyhow::Ok(())
        });
        if let Err(err) = result {
            eprintln!("local recording failed: {err:#}");
        }
    });
    *RECORDING.lock().unwrap() = Some(Recording {
        stop,
        handle: Some(handle),
    });
    0
}
#[ffi_export]
pub fn media_recording_stop() -> u8 {
    if let Some(mut recording) = RECORDING.lock().unwrap().take() {
        recording.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = recording.handle.take() {
            let _ = handle.join();
        }
        0
    } else {
        1
    }
}
#[ffi_export]
pub fn media_recording_duration_ms() -> u64 {
    RECORDING_DURATION.load(Ordering::Relaxed)
}
#[ffi_export]
pub fn media_recording_persist(ticket: char_p::Ref<'_>) -> u8 {
    let Ok(ticket) = ticket.to_str().parse::<BlobTicket>() else {
        return 1;
    };
    let result = tokio_executor(async {
        let endpoint = Endpoint::bind(presets::N0).await?;
        let root = media_path("persisted-blobs");
        let store = FsStore::load(&root).await?;
        store
            .downloader(&endpoint)
            .download(ticket.hash(), Some(ticket.addr().id))
            .await?;
        let output = media_path("fetched-blobs");
        std::fs::create_dir_all(&output)?;
        store
            .blobs()
            .export(ticket.hash(), output.join("received.wav"))
            .await?;
        endpoint.close().await;
        anyhow::Ok(())
    });
    u8::from(result.is_err())
}
#[ffi_export]
pub fn media_recording_play(ticket: char_p::Ref<'_>) -> u8 {
    media_recording_stop_playback();
    let path = if ticket.to_str().parse::<BlobTicket>().is_ok() {
        media_path("fetched-blobs").join("received.wav")
    } else {
        media_path("recording.wav")
    };
    if !path.exists() {
        return 1;
    }
    let Ok(data) = std::fs::read(&path) else {
        return 1;
    };
    let Some(format) = wav_format(&data) else {
        return 1;
    };
    if format.bits_per_sample != 16 {
        return 1;
    }
    let samples = data[format.data_offset..format.data_offset + format.data_len].to_vec();
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let handle = std::thread::spawn(move || {
        let result = tokio_executor(async {
            let mut playback_config = moq_audio::playback::Config::default();
            playback_config.device = OUTPUT_DEVICE.lock().unwrap().clone();
            let engine = moq_audio::playback::Engine::open(playback_config).await?;
            let mut input = moq_audio::playback::Input::default();
            input.format = Format::S16;
            input.sample_rate = format.sample_rate;
            input.channels = format.channels;
            let mut sink = engine.sink(input)?;
            let control = sink.control();
            control.set_volume(VOLUME.load(Ordering::Relaxed) as f32 / 100.0);
            *PLAYBACK_CONTROL.lock().unwrap() = Some(control);
            // 20 ms of interleaved s16 at the declared rate and channel count.
            let chunk_bytes = (format.sample_rate / 50) as usize * format.channels as usize * 2;
            for chunk in samples.chunks(chunk_bytes) {
                if thread_stop.load(Ordering::Relaxed) {
                    break;
                }
                sink.write(chunk)?;
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
            anyhow::Ok(())
        });
        if let Err(err) = result {
            eprintln!("playback failed: {err:#}");
        }
    });
    *PLAYBACK.lock().unwrap() = Some(Playback {
        stop,
        handle: Some(handle),
    });
    0
}
#[ffi_export]
pub fn media_recording_stop_playback() {
    PLAYBACK_CONTROL.lock().unwrap().take();
    PLAYBACK_ENGINE.lock().unwrap().take();
    if let Some(mut playback) = PLAYBACK.lock().unwrap().take() {
        playback.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = playback.handle.take() {
            let _ = handle.join();
        }
    }
}

/// In-app call tones (donpark/idfon#15, native shell): a small tone
/// generator writing synthesized PCM through the same device playback the
/// recordings use — no assets ship. `kind`: 0 stop, 1 ringback (loop),
/// 2 ringtone (loop), 3 answered (one-shot), 4 ended (one-shot). Every call
/// silences the previous tone first.
#[ffi_export]
pub fn media_call_tone(kind: u8) -> u8 {
    if let Some(mut tone) = TONE.lock().unwrap().take() {
        tone.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = tone.handle.take() {
            let _ = handle.join();
        }
    }
    if kind == 0 {
        return 0;
    }
    if kind > 4 {
        return 1;
    }
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let handle = std::thread::spawn(move || {
        let result = tokio_executor(async {
            let mut playback_config = moq_audio::playback::Config::default();
            playback_config.device = OUTPUT_DEVICE.lock().unwrap().clone();
            let engine = moq_audio::playback::Engine::open(playback_config).await?;
            let mut input = moq_audio::playback::Input::default();
            input.format = Format::S16;
            input.sample_rate = 48_000;
            input.channels = 1;
            let mut sink = engine.sink(input)?;
            let control = sink.control();
            control.set_volume(VOLUME.load(Ordering::Relaxed) as f32 / 100.0);
            let pattern = tone_pcm(kind);
            loop {
                for chunk in pattern.chunks(1_920) {
                    if thread_stop.load(Ordering::Relaxed) {
                        return anyhow::Ok(());
                    }
                    sink.write(chunk)?;
                    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                }
                if kind >= 3 {
                    return anyhow::Ok(()); // one-shot
                }
            }
        });
        if let Err(err) = result {
            eprintln!("call tone failed: {err:#}");
        }
    });
    *TONE.lock().unwrap() = Some(Playback {
        stop,
        handle: Some(handle),
    });
    0
}

/// One cadence of a call tone as S16 mono PCM at 48 kHz. Loops repeat the
/// cadence; the short edge fade keeps the loop click-free.
fn tone_pcm(kind: u8) -> Vec<u8> {
    const SAMPLE_RATE: f64 = 48_000.0;
    // (frequency Hz, seconds); 0 Hz is silence.
    let segments: &[(f64, f64)] = match kind {
        1 => &[(440.0, 0.6), (0.0, 0.6)],                // ringback
        2 => &[(800.0, 0.35), (640.0, 0.35), (0.0, 1.1)], // ringtone
        3 => &[(660.0, 0.12)],                            // answered
        _ => &[(440.0, 0.12), (330.0, 0.12)],             // ended
    };
    let mut pcm = Vec::new();
    for &(freq, secs) in segments {
        let frames = (SAMPLE_RATE * secs) as usize;
        for frame in 0..frames {
            let t = frame as f64 / SAMPLE_RATE;
            let edge = (frame.min(frames - frame) as f64 / 1_200.0).min(1.0); // ~25 ms fade
            let sample = (2.0 * std::f64::consts::PI * freq * t).sin() * 0.25 * edge;
            pcm.extend_from_slice(&((sample * i16::MAX as f64) as i16).to_le_bytes());
        }
    }
    pcm
}
#[ffi_export]
pub fn media_live_recording_samples() -> usize {
    let path = {
        let received = media_path("received.wav");
        if received.exists() {
            received
        } else {
            media_path("recording.wav")
        }
    };
    std::fs::read(path)
        .ok()
        .and_then(|data| wav_format(&data))
        // frames, not interleaved values: the waveform is a time axis
        .map(|format| format.data_len / 2 / format.channels.max(1) as usize)
        .unwrap_or(0)
}

/// Channel count the local recording's WAV header declares (1 when there is
/// no readable recording) — the voice-message envelope's `channels=` line.
#[ffi_export]
pub fn media_recording_channels() -> u32 {
    std::fs::read(media_path("recording.wav"))
        .ok()
        .and_then(|data| wav_format(&data))
        .map(|format| format.channels)
        .unwrap_or(1)
}
#[ffi_export]
pub fn media_live_recording_store() -> char_p::Box {
    let result = tokio_executor(async {
        let mut guard = BLOB_PROVIDER
            .lock()
            .map_err(|_| anyhow::anyhow!("blob provider poisoned"))?;
        if guard.is_none() {
            let endpoint = Endpoint::bind(presets::N0).await?;
            let store = FsStore::load(media_path("blobs")).await?;
            let router = Router::builder(endpoint.clone())
                .accept(BLOBS_ALPN, BlobsProtocol::new(store.as_ref(), None))
                .spawn();
            *guard = Some(BlobProvider {
                endpoint,
                store,
                _router: router,
            });
        }
        let provider = guard.as_ref().unwrap();
        let path = {
            let local = media_path("recording.wav");
            if local.exists() {
                local
            } else {
                media_path("received.wav")
            }
        };
        anyhow::ensure!(path.exists(), "no recording available");
        let content = provider.store.add_path(&path).await?;
        Ok::<String, anyhow::Error>(format!(
            "{}\n{}",
            RECORDING_DURATION.load(Ordering::Relaxed),
            BlobTicket::new(provider.endpoint.addr(), content.hash, content.format)
        ))
    });
    result.unwrap_or_default().try_into().unwrap()
}
#[ffi_export]
pub fn media_blob_fetch(ticket: char_p::Ref<'_>) -> u8 {
    let Ok(ticket) = ticket.to_str().parse::<BlobTicket>() else {
        return 1;
    };
    let result = tokio_executor(async {
        let endpoint = Endpoint::bind(presets::N0).await?;
        let root = media_path("fetched-blobs");
        let store = FsStore::load(&root).await?;
        store
            .downloader(&endpoint)
            .download(ticket.hash(), Some(ticket.addr().id))
            .await?;
        store
            .blobs()
            .export(ticket.hash(), root.join("received.wav"))
            .await?;
        endpoint.close().await;
        anyhow::Ok(())
    });
    u8::from(result.is_err())
}
#[ffi_export]
pub fn media_set_scope(scope: char_p::Ref<'_>) -> u8 {
    let path = scoped_media_dir(Path::new(scope.to_str()));
    if std::fs::create_dir_all(&path).is_err() {
        return 1;
    }
    *MEDIA_SCOPE.lock().unwrap() = Some(path);
    0
}
#[ffi_export]
pub fn media_emergency_stop() {
    media_live_stop();
}
#[ffi_export]
pub fn media_shutdown() {
    media_live_unsubscribe();
    media_recording_stop_playback();
    media_recording_stop();
    media_live_stop();
    if let Some(provider) = BLOB_PROVIDER.lock().unwrap().take() {
        tokio_executor(async {
            provider.endpoint.close().await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::AudioCodec;

    #[test]
    fn voice_agent_profiles_are_supported_but_other_rates_are_not() {
        assert!(super::supported_audio_profile(AudioCodec::Opus, 48_000));
        assert!(super::supported_audio_profile(AudioCodec::Pcm, 24_000));
        assert!(!super::supported_audio_profile(AudioCodec::Pcm, 48_000));
        assert!(!super::supported_audio_profile(AudioCodec::Opus, 24_000));
    }

    #[test]
    fn media_path_is_stable() {
        assert!(super::media_path("x").ends_with("x"));
    }

    #[test]
    fn frame_pts_gap_scales_with_channels() {
        // 20 ms @ 48 kHz: 960 mono samples, 1920 interleaved stereo samples.
        assert_eq!(super::frame_pts_gap_us(&vec![0u8; 960 * 4], 1), 20_000);
        assert_eq!(super::frame_pts_gap_us(&vec![0u8; 960 * 8], 2), 20_000);
    }

    #[test]
    fn stereo_wav_header_declares_two_channels() {
        let path = std::env::temp_dir().join(format!("idfon-stereo-{}.wav", std::process::id()));
        super::write_wav(&path, &[0.0, 0.0, 0.5, -0.5], 2).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        std::fs::remove_file(&path).ok();
        assert_eq!(u16::from_le_bytes([bytes[22], bytes[23]]), 2); // channels
        assert_eq!(u32::from_le_bytes(bytes[28..32].try_into().unwrap()), 192_000); // byte rate
        assert_eq!(u16::from_le_bytes([bytes[32], bytes[33]]), 4); // block align
    }

    #[test]
    fn wav_format_reads_the_declared_layout() {
        // write_wav's own stereo output.
        let path = std::env::temp_dir().join(format!("idfon-wavfmt-{}.wav", std::process::id()));
        super::write_wav(&path, &[0.0; 960 * 2], 2).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        std::fs::remove_file(&path).ok();
        let format = super::wav_format(&bytes).unwrap();
        assert_eq!(format.channels, 2);
        assert_eq!(format.sample_rate, 48_000);
        assert_eq!(format.bits_per_sample, 16);
        assert_eq!(format.data_len, 960 * 2 * 2);
        // The shells' memos: canonical 16 kHz mono s16 (AVAudioFile output
        // shape) must parse the same way — playback honors it.
        let mut memo = Vec::new();
        memo.extend_from_slice(b"RIFF");
        memo.extend_from_slice(&36u32.to_le_bytes());
        memo.extend_from_slice(b"WAVEfmt ");
        memo.extend_from_slice(&16u32.to_le_bytes());
        memo.extend_from_slice(&1u16.to_le_bytes());
        memo.extend_from_slice(&1u16.to_le_bytes());
        memo.extend_from_slice(&16_000u32.to_le_bytes());
        memo.extend_from_slice(&32_000u32.to_le_bytes());
        memo.extend_from_slice(&2u16.to_le_bytes());
        memo.extend_from_slice(&16u16.to_le_bytes());
        memo.extend_from_slice(b"data");
        memo.extend_from_slice(&4u32.to_le_bytes());
        memo.extend_from_slice(&[0, 0, 0, 0]);
        let format = super::wav_format(&memo).unwrap();
        assert_eq!(format.channels, 1);
        assert_eq!(format.sample_rate, 16_000);
        assert_eq!(format.data_offset, 44);
        assert_eq!(format.data_len, 4);
        assert!(super::wav_format(&[0u8; 44]).is_none());
    }

    #[test]
    fn relative_scope_stays_out_of_cwd() {
        let dir = super::scoped_media_dir(std::path::Path::new("peer-abc"));
        assert!(dir.is_absolute(), "bare scope must not be cwd-relative: {dir:?}");
        assert_eq!(dir.file_name().unwrap(), "peer-abc");
        // An absolute scope is used verbatim (the mac app passes one).
        let abs = super::scoped_media_dir(std::path::Path::new("/var/tmp/x"));
        assert_eq!(abs, std::path::PathBuf::from("/var/tmp/x"));
    }

    /// The stereo E2E without hardware (docs/stereo-calls.md): a shell-pushed
    /// L=440 / R=880 Hz tone through the real MoQ publish → decode path must
    /// arrive with channel separation intact. Direct addressing keeps it
    /// deterministic — a LiveTicket is id-only and resolves via pkarr/mDNS.
    #[test]
    fn stereo_tone_roundtrip_keeps_channel_separation() {
        use std::f32::consts::PI;
        use std::sync::atomic::Ordering;

        let _guard = crate::util::MEDIA_TEST_GUARD
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());

        // No speaker in CI: the shell render callback is a no-op sink.
        unsafe extern "C" fn discard(
            _: *const std::ffi::c_void,
            _: *const u8,
            _: usize,
            _: u32,
            _: u32,
            _: u64,
        ) {
        }
        assert_eq!(
            super::media_audio_set_playback_cb(std::ptr::null(), discard),
            0
        );
        let ticket_text =
            super::start_live(true, false, true, None, AudioCodec::Opus, 48_000, 2).expect("publish");
        let mut ticket = super::LiveTicket::deserialize(&ticket_text).expect("ticket");
        // Talk to the in-process publisher's address directly.
        ticket.endpoint = super::LIVE
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .live
            .endpoint()
            .addr();

        let pusher = std::thread::spawn(move || {
            for frame_index in 0..120u32 {
                let mut frame = vec![0f32; 960 * 2];
                for (n, pair) in frame.chunks_exact_mut(2).enumerate() {
                    let t = (frame_index as usize * 960 + n) as f32 / 48_000.0;
                    pair[0] = (2.0 * PI * 440.0 * t).sin() * 0.5;
                    pair[1] = (2.0 * PI * 880.0 * t).sin() * 0.5;
                }
                super::media_audio_push_frames(frame.as_ptr(), 960, 2);
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
        });

        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let watchdog = {
            let stop = stop.clone();
            std::thread::spawn(move || {
                // Deadlock guard, not a latency budget: the round trip must
                // finish eventually, however loaded the machine is. What the
                // test asserts is the captured audio, not the wall clock.
                for _ in 0..150 {
                    if stop.load(Ordering::Relaxed) {
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
                stop.store(true, Ordering::Relaxed);
            })
        };
        let mut samples = Vec::new();
        let mut timing = String::new();
        let mut decoded_total = 0;
        let mut channels = 0u32;
        let ended = super::tokio_executor(super::subscribe_decode_once(
            ticket,
            &stop,
            &mut samples,
            &mut timing,
            &mut decoded_total,
            std::time::Instant::now(),
            1,
            &mut channels,
        ));
        pusher.join().unwrap();
        stop.store(true, Ordering::Relaxed);
        watchdog.join().unwrap();
        super::media_live_stop();
        super::media_audio_clear_playback_cb();
        assert!(ended.expect("decode"), "watchdog should end the decode");
        assert_eq!(channels, 2, "stereo catalog must decode as stereo");
        assert!(samples.len() > 48_000, "capture too short: {}", samples.len());

        // Single-frequency correlation per channel, skipping the encoder's
        // first 0.2 s. 440 Hz must sit in ch0, 880 Hz in ch1 — and stay out
        // of the other one.
        let start = (48_000 / 5) as usize * 2;
        let magnitude = |channel: usize, freq: f32| -> f64 {
            let mut re = 0.0f64;
            let mut im = 0.0f64;
            let mut n = 0;
            while start + channel + 2 * n < samples.len() {
                let t = n as f64 / 48_000.0;
                let x = samples[start + channel + 2 * n] as f64;
                let phase = 2.0 * std::f64::consts::PI * freq as f64 * t;
                re += x * phase.cos();
                im += x * phase.sin();
                n += 1;
            }
            (re * re + im * im).sqrt()
        };
        let low = magnitude(0, 440.0);
        let high = magnitude(1, 880.0);
        assert!(low > 5.0 * magnitude(0, 880.0), "ch0 must carry 440 Hz");
        assert!(high > 5.0 * magnitude(1, 440.0), "ch1 must carry 880 Hz");
        assert!(low > 5.0 * magnitude(1, 440.0), "440 Hz must stay out of ch1");
        assert!(high > 5.0 * magnitude(0, 880.0), "880 Hz must stay out of ch0");
    }
}
