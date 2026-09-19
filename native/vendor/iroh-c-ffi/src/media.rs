//! Current native media bridge built on the current iroh-live/moq-media APIs.
//!
//! The old iroh-live media backend was intentionally removed. Native shells push
//! frames/samples into the current source model; capture and decode ownership
//! stays in moq-audio/moq-video.

use std::{collections::VecDeque, path::PathBuf, sync::{Arc, Mutex}, sync::atomic::{AtomicBool, Ordering}};

use iroh::{endpoint::presets, protocol::Router, Endpoint};
use iroh_blobs::{store::fs::FsStore, ticket::BlobTicket, BlobsProtocol, ALPN as BLOBS_ALPN};
use iroh_live::{ticket::LiveTicket, Live};
use moq_media::publish::{AudioSource, LocalBroadcast, VideoRendition, VideoSource};
use moq_audio::encode::{Options as AudioOptions, Publication, PublicationOptions};
use moq_audio::{Frame as AudioFrame, Format};
use moq_video::{Frame as VideoFrame, Size, Surface};
use n0_future::{boxed::BoxStream, stream::unfold};
use safer_ffi::prelude::*;

use crate::util::tokio_executor;

const AUDIO_CAPACITY: usize = 48_000 * 2;
static AUDIO_QUEUE: Mutex<Option<Arc<Mutex<VecDeque<f32>>>>> = Mutex::new(None);
static AUDIO_SAMPLES_PUSHED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static AUDIO_SAMPLES_NONZERO: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static AUDIO_FRAMES_ENCODED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static AUDIO_FRAMES_DECODED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static LIVE: Mutex<Option<LiveSession>> = Mutex::new(None);
static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);
static MEDIA_SCOPE: Mutex<Option<PathBuf>> = Mutex::new(None);
static LIVE_CONFIG: Mutex<Option<(bool, bool, bool, Option<PathBuf>)>> = Mutex::new(None);
static AUDIO_ENABLED: AtomicBool = AtomicBool::new(true);
static VIDEO_ENABLED: AtomicBool = AtomicBool::new(false);
static SUBSCRIBER: Mutex<Option<Subscriber>> = Mutex::new(None);
static RECORDING: Mutex<Option<Recording>> = Mutex::new(None);
static RECORDING_DURATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static BLOB_PROVIDER: Mutex<Option<BlobProvider>> = Mutex::new(None);
static VIDEO_QUEUE: Mutex<Option<(u32, u32, Vec<u8>, u64)>> = Mutex::new(None);
static VIDEO_FRAMES_PUSHED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static VIDEO_FRAMES_CONSUMED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static PLAYBACK: Mutex<Option<Playback>> = Mutex::new(None);
static PLAYBACK_CONTROL: Mutex<Option<moq_audio::playback::Control>> = Mutex::new(None);
static PLAYBACK_ENGINE: Mutex<Option<moq_audio::playback::Engine>> = Mutex::new(None);
static INPUT_DEVICE: Mutex<Option<String>> = Mutex::new(None);
static OUTPUT_DEVICE: Mutex<Option<String>> = Mutex::new(None);
static VOLUME: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(100);
static BITRATE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(32_000);

struct LiveSession {
    live: Live,
    _audio: Option<LocalBroadcast>,
    _video: Option<LocalBroadcast>,
}

struct Subscriber { stop: Arc<AtomicBool>, handle: Option<std::thread::JoinHandle<()>> }
struct Recording { stop: Arc<AtomicBool>, handle: Option<std::thread::JoinHandle<()>> }
struct BlobProvider { endpoint: Endpoint, store: FsStore, _router: Router }
struct Playback { stop: Arc<AtomicBool>, handle: Option<std::thread::JoinHandle<()>> }

pub(crate) fn media_path(name: &str) -> PathBuf {
    let root = MEDIA_SCOPE.lock().ok().and_then(|scope| scope.clone())
        .or_else(|| std::env::var_os("IDFON_MEDIA_DIR").map(PathBuf::from))
        .unwrap_or_else(|| std::env::temp_dir().join("idfon"));
    root.join(name)
}

fn audio_queue() -> Arc<Mutex<VecDeque<f32>>> {
    let mut slot = AUDIO_QUEUE.lock().expect("audio queue poisoned");
    slot.get_or_insert_with(|| Arc::new(Mutex::new(VecDeque::with_capacity(AUDIO_CAPACITY))))
        .clone()
}

fn audio_stream(queue: Arc<Mutex<VecDeque<f32>>>) -> BoxStream<AudioFrame> {
    Box::pin(unfold((queue, 0u64), |(queue, pts)| async move {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        let mut data = vec![0.0f32; 960];
        if AUDIO_ENABLED.load(Ordering::Relaxed) {
            let mut q = queue.lock().ok()?;
            for sample in &mut data {
                *sample = q.pop_front().unwrap_or(0.0);
            }
            let encoded = AUDIO_FRAMES_ENCODED.fetch_add(1, Ordering::Relaxed) + 1;
            if encoded <= 3 || encoded % 100 == 0 { eprintln!("[media] audio frame encoded #{}", encoded); }
        }
        let bytes: Vec<u8> = data.into_iter().flat_map(f32::to_le_bytes).collect();
        let timestamp = moq_net::Timestamp::from_micros(pts).ok()?;
        Some((AudioFrame::new(bytes::Bytes::from(bytes), timestamp), (queue, pts + 20_000)))
    }))
}

fn video_stream() -> BoxStream<VideoFrame> {
    Box::pin(unfold((), |_| async move {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            if !VIDEO_ENABLED.load(Ordering::Relaxed) { continue; }
            let Some((width, height, pixels, pts)) = VIDEO_QUEUE.lock().ok()?.take() else { continue; };
            VIDEO_FRAMES_CONSUMED.fetch_add(1, Ordering::Relaxed);
            let size = Size { width, height };
            let surface = Surface::rgba(&pixels, size).ok()?;
            let timestamp = moq_net::Timestamp::from_micros(pts).ok()?;
            return Some((VideoFrame::new(surface, timestamp), ()));
        }
    }))
}

fn start_live(audio: bool, video: bool, push_audio: bool, file_audio: Option<PathBuf>) -> anyhow::Result<String> {
    if !audio && !video { anyhow::bail!("at least one media track is required"); }
    let result = tokio_executor(async move {
        let live = Live::from_env().await?.with_router().spawn();
        let name = format!("idfon-live-{}", std::process::id());
        let mut combined_broadcast = None;
        if audio || video {
            let broadcast = live.publish(&name)?;
            if audio {
                let mut options = AudioOptions::default();
                options.codec = moq_audio::encode::Codec::Opus;
                options.bitrate = Some(BITRATE.load(Ordering::Relaxed) as u32);
                // Device capture is the default live source; pushed PCM remains
                // available through `media_audio_push_samples` for shell-owned taps.
                let source = if push_audio {
                    AudioSource::Frames {
                        input: moq_audio::encode::Input { format: Format::F32, sample_rate: 48_000, channels: 1 },
                        frames: audio_stream(audio_queue()),
                    }
                } else if let Some(path) = file_audio {
                    let file = moq_media::audio_file::AudioFile::open(path, false)?;
                    AudioSource::Frames { input: file.input(), frames: file.into_stream() }
                } else {
                    AudioSource::Device({
                        let mut config = moq_audio::capture::Config::default();
                        config.source = moq_audio::capture::Source::Microphone(INPUT_DEVICE.lock().unwrap().clone());
                        config
                    })
                };
                broadcast.audio().set_with(source, options);
            }
            if video {
                broadcast.video().set_renditions(
                    VideoSource::Frames(video_stream()),
                    vec![VideoRendition::new("video")],
                )?;
            }
            combined_broadcast = Some(broadcast);
        }
        let ticket = LiveTicket::new(live.endpoint().id(), &name).serialize();
        LIVE.lock().expect("live mutex poisoned").replace(LiveSession { live, _audio: combined_broadcast, _video: None });
        anyhow::Ok(ticket)
    });
    match result {
        Ok(ticket) => { *LAST_ERROR.lock().expect("error poisoned") = None; Ok(ticket) }
        Err(err) => { *LAST_ERROR.lock().expect("error poisoned") = Some(format!("{err:#}")); Err(err) }
    }
}

#[ffi_export]
pub fn media_live_start(audio: u8, video: u8) -> char_p::Box { media_live_start_inner(audio != 0, video != 0, false, None) }

fn media_live_start_inner(audio: bool, video: bool, push_audio: bool, file_audio: Option<PathBuf>) -> char_p::Box {
    match start_live(audio, video, push_audio, file_audio.clone()) {
        Ok(ticket) => {
            *LIVE_CONFIG.lock().unwrap() = Some((audio, video, push_audio, file_audio));
            ticket.try_into().unwrap()
        }
        Err(_) => String::new().try_into().unwrap(),
    }
}

#[ffi_export]
pub fn media_live_start_with_source(audio: u8, video: u8, source: char_p::Ref<'_>) -> char_p::Box {
    let source = source.to_str();
    let file = source.strip_prefix("file:").filter(|path| !path.is_empty()).map(PathBuf::from);
    if source != "mic" && source != "push" && file.is_none() {
        *LAST_ERROR.lock().unwrap() = Some(format!("unknown live source: {source}"));
        return String::new().try_into().unwrap();
    }
    media_live_start_inner(audio != 0, video != 0, source == "push", file)
}

#[ffi_export]
pub fn media_audio_push_samples(pcm: *const f32, samples: usize) {
    if pcm.is_null() || samples == 0 { return; }
    let pushed = AUDIO_SAMPLES_PUSHED.fetch_add(samples as u64, Ordering::Relaxed) + samples as u64;
    if pushed <= 2_000 || pushed % 48_000 < samples as u64 { eprintln!("[media] audio samples pushed total={}", pushed); }
    let input = unsafe { std::slice::from_raw_parts(pcm, samples) };
    let nonzero = input.iter().filter(|sample| sample.abs() > 0.0001).count() as u64;
    AUDIO_SAMPLES_NONZERO.fetch_add(nonzero, Ordering::Relaxed);
    if pushed <= 2_000 || pushed % 48_000 < samples as u64 {
        let peak = input.iter().fold(0.0f32, |peak, sample| peak.max(sample.abs()));
        let rms = (input.iter().map(|sample| sample * sample).sum::<f32>() / samples as f32).sqrt();
        eprintln!("[media] pushed audio samples={} nonzero={} rms={:.5} peak={:.5}", samples, nonzero, rms, peak);
    }
    let queue = audio_queue();
    let result = queue.lock();
    if let Ok(mut q) = result {
        q.extend(input.iter().copied());
        while q.len() > AUDIO_CAPACITY { q.pop_front(); }
    }
}

#[ffi_export]
pub fn media_live_set_audio_enabled(enabled: u8) -> u8 { AUDIO_ENABLED.store(enabled != 0, Ordering::Relaxed); 0 }
#[ffi_export]
pub fn media_live_set_video_enabled(enabled: u8) -> u8 {
    VIDEO_ENABLED.store(enabled != 0, Ordering::Relaxed);
    // Drop the frame parked while the camera was on: re-enabling would
    // otherwise encode it with a timestamp behind everything already sent.
    if enabled == 0 { if let Ok(mut slot) = VIDEO_QUEUE.lock() { *slot = None; } }
    eprintln!("[media] video enabled={} pushed={} consumed={}", enabled, VIDEO_FRAMES_PUSHED.load(Ordering::Relaxed), VIDEO_FRAMES_CONSUMED.load(Ordering::Relaxed));
    0
}
#[ffi_export]
pub fn media_live_last_error() -> char_p::Box { LAST_ERROR.lock().unwrap().clone().unwrap_or_default().try_into().unwrap() }
#[ffi_export]
pub fn media_live_stop() {
    if let Some(session) = LIVE.lock().unwrap().take() { tokio_executor(session.live.shutdown()); }
    *LIVE_CONFIG.lock().unwrap() = None;
    if let Ok(mut frame) = VIDEO_QUEUE.lock() { *frame = None; }
    if let Ok(mut queue) = AUDIO_QUEUE.lock() { *queue = None; }
}
#[ffi_export]
pub fn media_live_subscribe(ticket: char_p::Ref<'_>) -> u8 {
    media_live_unsubscribe();
    let Ok(ticket) = ticket.to_str().parse::<LiveTicket>() else { return 1; };
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let handle = std::thread::spawn(move || {
        let Ok(runtime) = tokio::runtime::Runtime::new() else { return; };
        let result = runtime.block_on(async move {
            let live = Live::from_env().await?.spawn();
            let subscription = live.subscribe(ticket.endpoint, &ticket.broadcast_name).await?;
            let broadcast = subscription.broadcast();
            // The publisher writes an empty catalog first and adds the audio
            // rendition once its encoder is probed, so the first snapshot a
            // fast subscriber sees may not carry it yet: wait for it.
            while !broadcast.has_audio() {
                if thread_stop.load(Ordering::Relaxed) { live.shutdown().await; return anyhow::Ok(()); }
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
            let catalog = broadcast.catalog();
            let Some(name) = catalog.first_audio() else { anyhow::bail!("broadcast has no audio track"); };
            let config = catalog.audio().get(name).ok_or_else(|| anyhow::anyhow!("audio catalog missing"))?;
            let mut decode = moq_audio::decode::Config::new();
            decode.format = Format::F32;
            decode.sample_rate = Some(48_000);
            decode.channels = Some(1);
            let mut consumer = moq_audio::decode::Consumer::new(broadcast.consumer(), config, name, decode).await?;
            let engine = moq_audio::playback::Engine::open({
                let mut playback = moq_audio::playback::Config::default();
                playback.device = OUTPUT_DEVICE.lock().unwrap().clone();
                playback
            }).await?;
            PLAYBACK_ENGINE.lock().unwrap().replace(engine.clone());
            let mut playback_input = moq_audio::playback::Input::default();
            playback_input.format = Format::F32;
            playback_input.sample_rate = 48_000;
            playback_input.channels = 1;
            let mut sink = engine.sink(playback_input)?;
            let control = sink.control();
            control.set_volume(VOLUME.load(Ordering::Relaxed) as f32 / 100.0);
            *PLAYBACK_CONTROL.lock().unwrap() = Some(control);
            let mut samples = Vec::new();
            while !thread_stop.load(Ordering::Relaxed) {
                let frame = match tokio::time::timeout(std::time::Duration::from_millis(200), consumer.read()).await {
                    Ok(frame) => frame?,
                    Err(_) => continue,
                };
                let Some(frame) = frame else { break; };
                sink.write(&frame.data)?;
                let decoded = AUDIO_FRAMES_DECODED.fetch_add(1, Ordering::Relaxed) + 1;
                if decoded <= 3 || decoded % 100 == 0 { eprintln!("[media] audio frame decoded #{}", decoded); }
                for chunk in frame.data.chunks_exact(4) { samples.push(f32::from_le_bytes(chunk.try_into().unwrap())); }
            }
            write_wav(&media_path("received.wav"), &samples)?;
            PLAYBACK_CONTROL.lock().unwrap().take();
            live.shutdown().await;
            anyhow::Ok(())
        });
        if let Err(err) = result { eprintln!("live subscribe failed: {err:#}"); }
    });
    *SUBSCRIBER.lock().unwrap() = Some(Subscriber { stop, handle: Some(handle) });
    0
}

fn write_wav(path: &std::path::Path, samples: &[f32]) -> anyhow::Result<()> {
    std::fs::create_dir_all(path.parent().unwrap_or(std::path::Path::new(".")))?;
    let mut bytes = Vec::with_capacity(44 + samples.len() * 2);
    let data_len = (samples.len() * 2) as u32;
    bytes.extend_from_slice(b"RIFF"); bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt "); bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes()); bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&48_000u32.to_le_bytes()); bytes.extend_from_slice(&96_000u32.to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes()); bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data"); bytes.extend_from_slice(&data_len.to_le_bytes());
    for sample in samples { bytes.extend_from_slice(&((sample.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes()); }
    std::fs::write(path, bytes)?;
    Ok(())
}

#[ffi_export]
pub fn media_live_unsubscribe() {
    media_recording_stop_playback();
    if let Some(mut sub) = SUBSCRIBER.lock().unwrap().take() {
        sub.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = sub.handle.take() { let _ = handle.join(); }
    }
}
#[ffi_export]
pub fn media_video_push_frame(data: *const u8, len: usize, width: u32, height: u32, pts_ms: u64) {
    if data.is_null() || width == 0 || height == 0 || len < width as usize * height as usize * 4 { return; }
    let pixels = unsafe { std::slice::from_raw_parts(data, width as usize * height as usize * 4) }.to_vec();
    let count = VIDEO_FRAMES_PUSHED.fetch_add(1, Ordering::Relaxed) + 1;
    if count <= 3 || count % 150 == 0 { eprintln!("[media] video frame pushed #{} {}x{} enabled={}", count, width, height, VIDEO_ENABLED.load(Ordering::Relaxed)); }
    if let Ok(mut slot) = VIDEO_QUEUE.lock() { *slot = Some((width, height, pixels, pts_ms * 1_000)); }
}

#[ffi_export]
pub fn media_audio_start() -> u8 { AUDIO_ENABLED.store(true, Ordering::Relaxed); 0 }
#[ffi_export]
pub fn media_audio_stop() { AUDIO_ENABLED.store(false, Ordering::Relaxed); }
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
    audio_queue().lock().map(|queue| queue.iter().filter(|sample| sample.abs() > 0.001).count()).unwrap_or(0)
}
#[ffi_export]
pub fn media_audio_input_count() -> usize {
    tokio_executor(async { moq_audio::capture::devices().await.map(|devices| devices.len()).unwrap_or(0) })
}
#[ffi_export]
pub fn media_audio_output_count() -> usize {
    tokio_executor(async { moq_audio::playback::devices().await.map(|devices| devices.len()).unwrap_or(0) })
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
        moq_audio::capture::devices().await.map(|devices| devices.into_iter().any(|item| item.id == id)).unwrap_or(false)
    });
    if !found { return 1; }
    *INPUT_DEVICE.lock().unwrap() = Some(id);
    let config = LIVE_CONFIG.lock().unwrap().clone();
    if let Some((audio, video, push, file)) = config {
        media_live_stop();
        if start_live(audio, video, push, file.clone()).is_ok() {
            *LIVE_CONFIG.lock().unwrap() = Some((audio, video, push, file));
        }
    }
    0
}
#[ffi_export]
pub fn media_audio_switch_output(device: char_p::Ref<'_>) -> u8 {
    let id = device.to_str().to_owned();
    let found = tokio_executor(async {
        moq_audio::playback::devices().await.map(|devices| devices.into_iter().any(|item| item.id == id)).unwrap_or(false)
    });
    if !found { return 1; }
    *OUTPUT_DEVICE.lock().unwrap() = Some(id.clone());
    if let Some(engine) = PLAYBACK_ENGINE.lock().unwrap().as_ref() {
        let mut config = moq_audio::playback::Config::default();
        config.device = Some(id);
        if tokio_executor(engine.switch(config)).is_err() { return 1; }
    }
    0
}
#[ffi_export]
pub fn media_audio_set_bitrate(bitrate: u32) -> u8 {
    if !(8_000..=510_000).contains(&bitrate) { return 1; }
    BITRATE.store(bitrate as u64, Ordering::Relaxed);
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
            options.capture.source = moq_audio::capture::Source::Microphone(INPUT_DEVICE.lock().unwrap().clone());
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
            let name = catalog.first_audio().ok_or_else(|| anyhow::anyhow!("recording audio track unavailable"))?.to_owned();
            let config = catalog.audio().get(&name).ok_or_else(|| anyhow::anyhow!("recording catalog unavailable"))?.clone();
            let mut decode = moq_audio::decode::Config::new();
            decode.format = Format::F32;
            decode.sample_rate = Some(48_000);
            decode.channels = Some(1);
            let mut consumer = moq_audio::decode::Consumer::new(broadcast.consumer(), &config, &name, decode).await?;
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
            write_wav(&media_path("recording.wav"), &samples)?;
            RECORDING_DURATION.store(started.elapsed().as_millis() as u64, Ordering::Relaxed);
            drop(publication);
            live.shutdown().await;
            anyhow::Ok(())
        });
        if let Err(err) = result { eprintln!("local recording failed: {err:#}"); }
    });
    *RECORDING.lock().unwrap() = Some(Recording { stop, handle: Some(handle) });
    0
}
#[ffi_export]
pub fn media_recording_stop() -> u8 {
    if let Some(mut recording) = RECORDING.lock().unwrap().take() {
        recording.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = recording.handle.take() { let _ = handle.join(); }
        0
    } else { 1 }
}
#[ffi_export]
pub fn media_recording_duration_ms() -> u64 { RECORDING_DURATION.load(Ordering::Relaxed) }
#[ffi_export]
pub fn media_recording_persist(ticket: char_p::Ref<'_>) -> u8 {
    let Ok(ticket) = ticket.to_str().parse::<BlobTicket>() else { return 1; };
    let result = tokio_executor(async {
        let endpoint = Endpoint::bind(presets::N0).await?;
        let root = media_path("persisted-blobs");
        let store = FsStore::load(&root).await?;
        store.downloader(&endpoint).download(ticket.hash(), Some(ticket.addr().id)).await?;
        let output = media_path("fetched-blobs");
        std::fs::create_dir_all(&output)?;
        store.blobs().export(ticket.hash(), output.join("received.wav")).await?;
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
    if !path.exists() { return 1; }
    let Ok(data) = std::fs::read(&path) else { return 1; };
    if data.len() < 44 || &data[0..4] != b"RIFF" { return 1; }
    let samples = data[44..].to_vec();
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
            *PLAYBACK_CONTROL.lock().unwrap() = Some(control);
            for chunk in samples.chunks(1_920) {
                if thread_stop.load(Ordering::Relaxed) { break; }
                sink.write(chunk)?;
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
            anyhow::Ok(())
        });
        if let Err(err) = result { eprintln!("playback failed: {err:#}"); }
    });
    *PLAYBACK.lock().unwrap() = Some(Playback { stop, handle: Some(handle) });
    0
}
#[ffi_export]
pub fn media_recording_stop_playback() {
    PLAYBACK_CONTROL.lock().unwrap().take();
    PLAYBACK_ENGINE.lock().unwrap().take();
    if let Some(mut playback) = PLAYBACK.lock().unwrap().take() {
        playback.stop.store(true, Ordering::Relaxed);
        if let Some(handle) = playback.handle.take() { let _ = handle.join(); }
    }
}
#[ffi_export]
pub fn media_live_recording_samples() -> usize {
    let path = {
        let received = media_path("received.wav");
        if received.exists() { received } else { media_path("recording.wav") }
    };
    std::fs::metadata(path)
        .map(|metadata| metadata.len().saturating_sub(44) as usize / 2)
        .unwrap_or(0)
}
#[ffi_export]
pub fn media_live_recording_store() -> char_p::Box {
    let result = tokio_executor(async {
        let mut guard = BLOB_PROVIDER.lock().map_err(|_| anyhow::anyhow!("blob provider poisoned"))?;
        if guard.is_none() {
            let endpoint = Endpoint::bind(presets::N0).await?;
            let store = FsStore::load(media_path("blobs")).await?;
            let router = Router::builder(endpoint.clone()).accept(BLOBS_ALPN, BlobsProtocol::new(store.as_ref(), None)).spawn();
            *guard = Some(BlobProvider { endpoint, store, _router: router });
        }
        let provider = guard.as_ref().unwrap();
        let path = {
            let local = media_path("recording.wav");
            if local.exists() { local } else { media_path("received.wav") }
        };
        anyhow::ensure!(path.exists(), "no recording available");
        let content = provider.store.add_path(&path).await?;
        Ok::<String, anyhow::Error>(format!("{}\n{}", RECORDING_DURATION.load(Ordering::Relaxed), BlobTicket::new(provider.endpoint.addr(), content.hash, content.format)))
    });
    result.unwrap_or_default().try_into().unwrap()
}
#[ffi_export]
pub fn media_blob_fetch(ticket: char_p::Ref<'_>) -> u8 {
    let Ok(ticket) = ticket.to_str().parse::<BlobTicket>() else { return 1; };
    let result = tokio_executor(async {
        let endpoint = Endpoint::bind(presets::N0).await?;
        let root = media_path("fetched-blobs");
        let store = FsStore::load(&root).await?;
        store.downloader(&endpoint).download(ticket.hash(), Some(ticket.addr().id)).await?;
        store.blobs().export(ticket.hash(), root.join("received.wav")).await?;
        endpoint.close().await;
        anyhow::Ok(())
    });
    u8::from(result.is_err())
}
#[ffi_export]
pub fn media_set_scope(scope: char_p::Ref<'_>) -> u8 {
    let path = PathBuf::from(scope.to_str());
    if std::fs::create_dir_all(&path).is_err() { return 1; }
    *MEDIA_SCOPE.lock().unwrap() = Some(path);
    0
}
#[ffi_export]
pub fn media_emergency_stop() { media_live_stop(); }
#[ffi_export]
pub fn media_shutdown() {
    media_live_unsubscribe();
    media_recording_stop_playback();
    media_recording_stop();
    media_live_stop();
    if let Some(provider) = BLOB_PROVIDER.lock().unwrap().take() { tokio_executor(async { provider.endpoint.close().await; }); }
}

#[cfg(test)]
mod tests {
    #[test]
    fn media_path_is_stable() { assert!(super::media_path("x").ends_with("x")); }
}
