//! Rust-owned audio capture, live publishing, and decoded-audio recording.

use std::{
    fs::{self, File, OpenOptions},
    io::{Seek, SeekFrom, Write},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    thread,
    time::{Duration, Instant},
};

use bytes::Bytes;
use iroh::protocol::Router;
use iroh_blobs::{store::fs::FsStore, ticket::BlobTicket, BlobsProtocol, ALPN as BLOBS_ALPN};
use iroh_live::{
    media::{
        audio_backend::InputStream,
        codec::AudioCodec,
        codec::OpusEncoder,
        format::{AudioEncoderConfig, AudioFormat, AudioPreset, PlaybackConfig},
        publish::{AudioRenditions, LocalBroadcast},
        subscribe::MediaTracks,
        traits::{
            AudioDecoder, AudioEncoder, AudioEncoderFactory, AudioSink, AudioSinkHandle,
            AudioSource, AudioStreamFactory,
        },
        AudioBackend,
    },
    ticket::LiveTicket,
    Live, Subscription,
};
use n0_future::boxed::BoxFuture;
use ogg::reading::PacketReader;
use safer_ffi::prelude::*;

use crate::util::tokio_executor;

static AUDIO: OnceLock<AudioBackend> = OnceLock::new();
static MEDIA_SCOPE: Mutex<Option<String>> = Mutex::new(None);
static RECORDING_HISTORY: Mutex<()> = Mutex::new(());
static INPUT: Mutex<Option<InputStream>> = Mutex::new(None);
static LIVE: Mutex<Option<LiveSession>> = Mutex::new(None);
static SUBSCRIBER: Mutex<Option<Subscriber>> = Mutex::new(None);
// Live audio encode target in bits per second (Opus VBR, so actual wire
// usage dips below this on silence). Sender-configurable via
// media_audio_set_bitrate; applies to the next live publisher start.
static BITRATE: AtomicU64 = AtomicU64::new(32_000);
static BLOB_PROVIDER: Mutex<Option<BlobProvider>> = Mutex::new(None);
static LOCAL_RECORDING: Mutex<Option<LocalRecording>> = Mutex::new(None);
static LAST_RECORDING_DURATION_MS: AtomicU64 = AtomicU64::new(0);
static PLAYBACK: Mutex<Option<Playback>> = Mutex::new(None);

struct LiveSession {
    _live: Live,
    _broadcast: LocalBroadcast,
}

struct Subscriber {
    _live: Live,
    _subscription: Subscription,
    _tracks: MediaTracks,
    recording: Arc<Mutex<WavRecorder>>,
}

struct BlobProvider {
    _live: Live,
    _store: FsStore,
    _router: Router,
}

struct LocalRecording {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
    recorder: Arc<Mutex<OggOpusRecorder>>,
    peak: Arc<Mutex<f32>>,
    started: Instant,
}

struct Playback {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

/// Silences the microphone toward the live publisher while a local recording
/// is active: the user can prepare a voice message mid-call without the peer
/// hearing it. Sits between the capture device and the Opus encoder.
struct MuteSource {
    inner: InputStream,
}

impl AudioSource for MuteSource {
    fn format(&self) -> AudioFormat {
        self.inner.format()
    }
    fn pop_samples(&mut self, buf: &mut [f32]) -> anyhow::Result<Option<usize>> {
        let result = self.inner.pop_samples(buf);
        if LOCAL_RECORDING
            .lock()
            .expect("recording mutex poisoned")
            .is_some()
        {
            for sample in buf.iter_mut() {
                *sample = 0.0;
            }
        }
        result
    }
}

fn audio() -> &'static AudioBackend {
    let backend = AUDIO.get_or_init(AudioBackend::default);
    // ponytail: AEC disabled — sonora's EchoRemover panics (slice index OOB,
    // panic=abort → SIGABRT) on the CoreAudio IO thread when a mono output
    // stream (48k/1 opus live track) joins the 2ch-configured AEC. The input
    // device is 1ch while the AEC config is hardcoded 2ch, so cancellation was
    // processing mono-as-stereo garbage anyway. Re-enable when iroh-live/sonora
    // handles channel-count mismatches; echo risk until then.
    backend.set_aec_enabled(false);
    backend
}

fn media_dir() -> std::path::PathBuf {
    let root = std::env::var_os("NATIVE_SDK_APP_DATA_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp/nufon"));
    let scope = MEDIA_SCOPE
        .lock()
        .expect("media scope mutex poisoned")
        .clone()
        .unwrap_or_else(|| "default".to_owned());
    let mut safe = String::with_capacity(scope.len().min(96));
    for byte in scope.bytes().take(96) {
        if byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_' {
            safe.push(byte as char);
        } else {
            safe.push('_');
        }
    }
    let root = root
        .join("conversations")
        .join(if safe.is_empty() { "default" } else { &safe });
    let _ = fs::create_dir_all(&root);
    root
}

fn broadcast_name() -> String {
    let scope = MEDIA_SCOPE
        .lock()
        .expect("media scope mutex poisoned")
        .clone()
        .unwrap_or_else(|| "default".to_owned());
    let mut name = String::from("nufon-audio-");
    for byte in scope.bytes().take(64) {
        name.push(
            if byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_' {
                byte as char
            } else {
                '_'
            },
        );
    }
    name
}

fn media_path(name: &str) -> std::path::PathBuf {
    media_dir().join(name)
}

/// Persists a recording ticket once in the active conversation's ledger.
#[ffi_export]
pub fn media_recording_persist(ticket: char_p::Ref<'_>) -> u8 {
    let ticket = ticket.to_str();
    tracing::info!(ticket_len = ticket.len(), "recording persist requested");
    if ticket.is_empty()
        || ticket
            .bytes()
            .any(|byte| byte == 0 || byte == b'\n' || byte == b'\r')
    {
        return 1;
    }
    if ticket.parse::<BlobTicket>().is_err() {
        tracing::warn!("recording persist rejected: invalid blob ticket");
        return 1;
    }
    let _guard = RECORDING_HISTORY
        .lock()
        .expect("recording history mutex poisoned");
    let path = media_path("recording-history.log");
    let existing = fs::read_to_string(&path).unwrap_or_default();
    if existing.lines().any(|line| line == ticket) {
        tracing::info!("recording persist duplicate");
        return 0;
    }
    let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) else {
        return 1;
    };
    if writeln!(file, "{ticket}").is_err() {
        return 1;
    }
    tracing::info!("recording persist complete");
    0
}

/// Selects the identity/conversation namespace used by subsequent media operations.
#[ffi_export]
pub fn media_set_scope(scope: char_p::Ref<'_>) -> u8 {
    let scope = scope.to_str();
    if scope.is_empty()
        || scope.len() > 4096
        || scope.bytes().any(|byte| byte == 0 || byte == b'\n')
    {
        return 1;
    }
    *MEDIA_SCOPE.lock().expect("media scope mutex poisoned") = Some(scope.to_owned());
    tracing::info!(scope_len = scope.len(), "media scope selected");
    0
}

#[derive(Debug)]
struct OggOpusRecorder {
    file: File,
    encoder: OpusEncoder,
    serial: u32,
    sequence: u32,
    granule: u64,
}

impl OggOpusRecorder {
    fn create(path: &str) -> anyhow::Result<Self> {
        let format = AudioFormat::mono_48k();
        let encoder = OpusEncoder::with_preset(format, AudioPreset::Hq)?;
        let mut this = Self {
            file: File::create(path)?,
            encoder,
            serial: 0x4e55464f,
            sequence: 0,
            granule: 0,
        };
        this.write_packet(
            b"OpusHead\x01\x01\x38\x01\x80\xbb\x00\x00\x00\x00\x00",
            0,
            true,
            false,
        )?;
        this.write_packet(
            b"OpusTags\x05\x00\x00\x00Nufon\x00\x00\x00\x00",
            0,
            false,
            false,
        )?;
        Ok(this)
    }

    fn push(&mut self, samples: &[f32]) -> anyhow::Result<()> {
        self.encoder.push_samples(samples)?;
        while let Some(packet) = self.encoder.pop_packet()? {
            self.granule += 960;
            self.write_packet(&packet.payload, self.granule, false, false)?;
        }
        Ok(())
    }

    fn finish(&mut self) -> anyhow::Result<()> {
        // OpusEncoder buffers until a complete 20 ms frame. Pad the tail so
        // short recordings and a final partial capture are not discarded.
        self.encoder.push_samples(&vec![0.0f32; 960])?;
        while let Some(packet) = self.encoder.pop_packet()? {
            self.granule += 960;
            self.write_packet(&packet.payload, self.granule, false, false)?;
        }
        self.write_packet(&[], self.granule, false, true)
    }

    fn write_packet(
        &mut self,
        packet: &[u8],
        granule: u64,
        bos: bool,
        eos: bool,
    ) -> anyhow::Result<()> {
        let mut offset = 0;
        let mut first = true;
        while offset < packet.len() || first {
            let remaining = packet.len() - offset;
            let payload_len = remaining.min(255 * 255);
            let mut lacing = Vec::new();
            let mut left = payload_len;
            while left >= 255 {
                lacing.push(255);
                left -= 255;
            }
            lacing.push(left as u8);
            let mut page = Vec::with_capacity(27 + lacing.len() + payload_len);
            page.extend_from_slice(b"OggS");
            page.push(0);
            page.push(if first && bos {
                2
            } else if offset + payload_len == packet.len() && eos {
                4
            } else if !first {
                1
            } else {
                0
            });
            page.extend_from_slice(&granule.to_le_bytes());
            page.extend_from_slice(&self.serial.to_le_bytes());
            page.extend_from_slice(&self.sequence.to_le_bytes());
            page.extend_from_slice(&0u32.to_le_bytes());
            page.push(lacing.len() as u8);
            page.extend_from_slice(&lacing);
            page.extend_from_slice(&packet[offset..offset + payload_len]);
            let crc = ogg_crc(&page);
            page[22..26].copy_from_slice(&crc.to_le_bytes());
            self.file.write_all(&page)?;
            self.sequence += 1;
            offset += payload_len;
            first = false;
            if payload_len == 0 {
                break;
            }
        }
        Ok(())
    }
}

fn ogg_crc(page: &[u8]) -> u32 {
    let mut crc = 0u32;
    for &byte in page {
        crc ^= (byte as u32) << 24;
        for _ in 0..8 {
            crc = if crc & 0x8000_0000 != 0 {
                (crc << 1) ^ 0x04c1_1db7
            } else {
                crc << 1
            };
        }
    }
    crc
}

#[derive(Debug)]
struct WavRecorder {
    file: File,
    format: AudioFormat,
    data_bytes: u32,
    samples: usize,
}

impl WavRecorder {
    fn create(path: &str, format: AudioFormat) -> std::io::Result<Self> {
        let mut recorder = Self {
            file: File::create(path)?,
            format,
            data_bytes: 0,
            samples: 0,
        };
        recorder.write_header()?;
        Ok(recorder)
    }

    fn write_header(&mut self) -> std::io::Result<()> {
        let channels = self.format.channel_count as u16;
        let rate = self.format.sample_rate;
        let byte_rate = rate * channels as u32 * 2;
        let block_align = channels * 2;
        self.file.seek(SeekFrom::Start(0))?;
        self.file.write_all(b"RIFF")?;
        self.file
            .write_all(&(36u32 + self.data_bytes).to_le_bytes())?;
        self.file.write_all(b"WAVEfmt ")?;
        self.file.write_all(&16u32.to_le_bytes())?;
        self.file.write_all(&1u16.to_le_bytes())?;
        self.file.write_all(&channels.to_le_bytes())?;
        self.file.write_all(&rate.to_le_bytes())?;
        self.file.write_all(&byte_rate.to_le_bytes())?;
        self.file.write_all(&block_align.to_le_bytes())?;
        self.file.write_all(&16u16.to_le_bytes())?;
        self.file.write_all(b"data")?;
        self.file.write_all(&self.data_bytes.to_le_bytes())?;
        Ok(())
    }

    fn push(&mut self, samples: &[f32]) -> std::io::Result<()> {
        for sample in samples {
            let pcm = (sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
            self.file.write_all(&pcm.to_le_bytes())?;
        }
        self.data_bytes = self.data_bytes.saturating_add((samples.len() * 2) as u32);
        self.samples += samples.len() / self.format.channel_count as usize;
        Ok(())
    }

    fn finish(&mut self) -> std::io::Result<()> {
        self.write_header()?;
        self.file.seek(SeekFrom::End(0))?;
        self.file.flush()
    }
}

#[derive(Debug)]
struct RecordingSinkHandle {
    paused: Arc<std::sync::atomic::AtomicBool>,
}

impl AudioSinkHandle for RecordingSinkHandle {
    fn cloned_boxed(&self) -> Box<dyn AudioSinkHandle> {
        Box::new(Self {
            paused: self.paused.clone(),
        })
    }
    fn pause(&self) {
        self.paused
            .store(true, std::sync::atomic::Ordering::Relaxed);
    }
    fn resume(&self) {
        self.paused
            .store(false, std::sync::atomic::Ordering::Relaxed);
    }
    fn is_paused(&self) -> bool {
        self.paused.load(std::sync::atomic::Ordering::Relaxed)
    }
    fn toggle_pause(&self) {
        let old = self.is_paused();
        self.paused
            .store(!old, std::sync::atomic::Ordering::Relaxed);
    }
}

struct NullAudioSink {
    format: AudioFormat,
    handle: RecordingSinkHandle,
}

impl AudioSinkHandle for NullAudioSink {
    fn cloned_boxed(&self) -> Box<dyn AudioSinkHandle> {
        self.handle.cloned_boxed()
    }
    fn pause(&self) {
        self.handle.pause();
    }
    fn resume(&self) {
        self.handle.resume();
    }
    fn is_paused(&self) -> bool {
        self.handle.is_paused()
    }
    fn toggle_pause(&self) {
        self.handle.toggle_pause();
    }
}

impl AudioSink for NullAudioSink {
    fn format(&self) -> anyhow::Result<AudioFormat> {
        Ok(self.format)
    }
    fn push_samples(&mut self, _samples: &[f32]) -> anyhow::Result<()> {
        Ok(())
    }
    fn handle(&self) -> Box<dyn AudioSinkHandle> {
        self.handle.cloned_boxed()
    }
}

struct RecordingSink {
    format: AudioFormat,
    recorder: Arc<Mutex<WavRecorder>>,
    output: Box<dyn AudioSink>,
    handle: RecordingSinkHandle,
}

impl std::fmt::Debug for RecordingSink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RecordingSink")
            .field("format", &self.format)
            .finish()
    }
}

impl AudioSinkHandle for RecordingSink {
    fn cloned_boxed(&self) -> Box<dyn AudioSinkHandle> {
        self.handle.cloned_boxed()
    }
    fn pause(&self) {
        self.handle.pause();
        self.output.pause();
    }
    fn resume(&self) {
        self.handle.resume();
        self.output.resume();
    }
    fn is_paused(&self) -> bool {
        self.handle.is_paused()
    }
    fn toggle_pause(&self) {
        self.handle.toggle_pause();
        self.output.toggle_pause();
    }
}

impl AudioSink for RecordingSink {
    fn format(&self) -> anyhow::Result<AudioFormat> {
        Ok(self.format)
    }
    fn push_samples(&mut self, samples: &[f32]) -> anyhow::Result<()> {
        // Mute the speaker while a local recording is active: there is no
        // echo cancellation, so peer audio would bleed into the recording.
        // The subscribed-call WAV recording keeps running regardless.
        if LOCAL_RECORDING
            .lock()
            .expect("recording mutex poisoned")
            .is_none()
        {
            self.output.push_samples(samples)?;
        }
        if !self.handle.is_paused() {
            self.recorder
                .lock()
                .expect("recorder mutex poisoned")
                .push(samples)?;
        }
        Ok(())
    }
    fn handle(&self) -> Box<dyn AudioSinkHandle> {
        self.handle.cloned_boxed()
    }
}

#[derive(Clone, Debug)]
struct RecordingBackend {
    recorder: Arc<Mutex<WavRecorder>>,
    output: AudioBackend,
}

impl AudioStreamFactory for RecordingBackend {
    fn create_input(
        &self,
        _format: AudioFormat,
    ) -> BoxFuture<anyhow::Result<Box<dyn AudioSource>>> {
        Box::pin(async { anyhow::bail!("recording backend has no input") })
    }
    fn create_output(&self, format: AudioFormat) -> BoxFuture<anyhow::Result<Box<dyn AudioSink>>> {
        let recorder = self.recorder.clone();
        let output = self.output.clone();
        Box::pin(async move {
            let handle = RecordingSinkHandle {
                paused: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            };
            let output = match output.create_output(format).await {
                Ok(output) => output,
                Err(error) => {
                    tracing::warn!("audio output unavailable; recording live audio without playback: {error:#}");
                    Box::new(NullAudioSink {
                        format,
                        handle: RecordingSinkHandle {
                            paused: handle.paused.clone(),
                        },
                    }) as Box<dyn AudioSink>
                }
            };
            Ok(Box::new(RecordingSink {
                format,
                recorder,
                output,
                handle,
            }) as Box<dyn AudioSink>)
        })
    }
}

/// Downloads and exports a blob to a per-hash file unless it is already present.
/// Returns the exported path.
fn ensure_fetched(ticket: &BlobTicket) -> anyhow::Result<std::path::PathBuf> {
    tokio_executor(async {
        let endpoint = iroh::Endpoint::bind(iroh::endpoint::presets::N0).await?;
        let store = FsStore::load(media_dir().join("fetched-blobs")).await?;
        let fetched = media_dir()
            .join("fetched-blobs")
            .join(format!("{}.opus", ticket.hash()));
        if !fetched.exists() {
            store
                .downloader(&endpoint)
                .download(ticket.hash(), Some(ticket.addr().id))
                .await?;
            store.blobs().export(ticket.hash(), &fetched).await?;
        }
        endpoint.close().await;
        anyhow::Ok(fetched)
    })
}

/// Plays the fetched recording through the default output device.
/// Returns `0` on success and `1` on failure.
#[ffi_export]
pub fn media_recording_play(ticket: char_p::Ref<'_>) -> u8 {
    let Ok(ticket) = ticket.to_str().parse::<BlobTicket>() else {
        tracing::warn!("recording playback rejected: invalid ticket");
        return 1;
    };
    // per-message playback: a new play supersedes the previous one
    media_recording_stop_playback();
    let path = match ensure_fetched(&ticket) {
        Ok(path) => path,
        Err(err) => {
            tracing::warn!("recording playback fetch failed: {err:#}");
            return 1;
        }
    };
    if !path.exists() {
        return 1;
    }
    let file = match File::open(&path) {
        Ok(file) => file,
        Err(err) => {
            tracing::warn!(path = %path.display(), "recording playback open failed: {err:#}");
            return 1;
        }
    };
    tracing::info!(path = %path.display(), bytes = file.metadata().map(|value| value.len()).unwrap_or(0), "recording playback started");
    let mut packets = PacketReader::new(file);
    let config = iroh_live::media::config::AudioConfig {
        codec: iroh_live::media::config::AudioCodec::Opus,
        sample_rate: 48_000,
        channel_count: 1,
        bitrate: Some(128_000),
        description: None,
    };
    let mut decoder =
        match iroh_live::media::codec::OpusAudioDecoder::new(&config, AudioFormat::stereo_48k()) {
            Ok(decoder) => decoder,
            Err(_) => return 1,
        };
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let thread = thread::spawn(move || {
        let mut output = match tokio_executor(audio().default_output()) {
            Ok(output) => output,
            Err(err) => {
                tracing::warn!("recording playback output initialization failed: {err:#}");
                return;
            }
        };
        let mut decoded_packets = 0usize;
        let mut decoded_samples = 0usize;
        let mut peak = 0.0f32;
        let mut prebuffered = 0usize;
        let mut playback_deadline = Instant::now() + Duration::from_millis(200);
        while !thread_stop.load(Ordering::Relaxed) {
            let packet = match packets.read_packet() {
                Ok(Some(packet)) => packet,
                Ok(None) | Err(_) => break,
            };
            if packet.data.starts_with(b"OpusHead") || packet.data.starts_with(b"OpusTags") {
                continue;
            }
            let media_packet = iroh_live::media::format::MediaPacket {
                timestamp: Duration::ZERO,
                payload: buf_list::BufList::from(Bytes::from(packet.data)),
                is_keyframe: true,
            };
            match decoder.push_packet(media_packet) {
                Ok(()) => {
                    if let Ok(Some(samples)) = decoder.pop_samples() {
                        decoded_packets += 1;
                        decoded_samples += samples.len();
                        for sample in samples {
                            peak = peak.max(sample.abs());
                        }
                        if let Err(err) = output.push_samples(samples) {
                            tracing::warn!("recording playback output failed: {err:#}");
                            break;
                        }
                        // Prebuffer before starting the device clock. Without
                        // this, callback scheduling can drain each 20 ms frame
                        // before the next one is submitted, producing pops.
                        prebuffered += 1;
                        if prebuffered >= 10 {
                            let frame_duration =
                                Duration::from_secs_f64(samples.len() as f64 / (48_000.0 * 2.0));
                            playback_deadline += frame_duration;
                            if let Some(remaining) =
                                playback_deadline.checked_duration_since(Instant::now())
                            {
                                if !thread_stop.load(Ordering::Relaxed) {
                                    thread::sleep(remaining);
                                }
                            }
                        }
                    }
                }
                Err(err) => {
                    tracing::warn!("recording playback Opus decode failed: {err:#}");
                    break;
                }
            }
        }
        if !thread_stop.load(Ordering::Relaxed) {
            if let Some(remaining) = playback_deadline.checked_duration_since(Instant::now()) {
                thread::sleep(remaining);
            }
        }
        tracing::info!(
            decoded_packets,
            decoded_samples,
            peak,
            "recording playback finished"
        );
    });
    *PLAYBACK.lock().expect("playback mutex poisoned") = Some(Playback {
        stop,
        thread: Some(thread),
    });
    0
}

/// Stops fetched-recording playback.
#[ffi_export]
pub fn media_recording_stop_playback() {
    if let Some(mut playback) = PLAYBACK.lock().expect("playback mutex poisoned").take() {
        playback.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = playback.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Returns the number of currently enumerated output devices.
#[ffi_export]
pub fn media_audio_output_count() -> usize {
    AudioBackend::list_outputs().len()
}

/// Sets the active subscriber output volume from 0 to 100.
#[ffi_export]
pub fn media_audio_set_volume(percent: u8) -> u8 {
    let volume = (percent.min(100) as f32) / 100.0;
    let subscriber = SUBSCRIBER.lock().expect("subscriber mutex poisoned");
    let Some(track) = subscriber
        .as_ref()
        .and_then(|value| value._tracks.audio.as_ref())
    else {
        return 1;
    };
    track.set_volume(volume);
    0
}

/// Switches the microphone input device by its cpal device identifier.
#[ffi_export]
pub fn media_audio_switch_input(device: char_p::Ref<'_>) -> u8 {
    let device = match device.to_str().parse() {
        Ok(device) => device,
        Err(_) => return 1,
    };
    match tokio_executor(audio().switch_input(Some(device))) {
        Ok(()) => 0,
        Err(err) => {
            tracing::warn!("failed to switch input device: {err:#}");
            1
        }
    }
}

/// Switches the speaker output device by its cpal device identifier.
#[ffi_export]
pub fn media_audio_switch_output(device: char_p::Ref<'_>) -> u8 {
    let device = match device.to_str().parse() {
        Ok(device) => device,
        Err(_) => return 1,
    };
    match tokio_executor(audio().switch_output(Some(device))) {
        Ok(()) => 0,
        Err(err) => {
            tracing::warn!("failed to switch output device: {err:#}");
            1
        }
    }
}

/// Returns the number of currently enumerated input devices.
#[ffi_export]
pub fn media_audio_input_count() -> usize {
    AudioBackend::list_inputs().len()
}

/// Starts the default 48 kHz mono microphone stream.
#[ffi_export]
pub fn media_audio_start() -> u8 {
    tracing::info!("audio start requested");
    let result = tokio_executor(audio().default_input());
    let Ok(input) = result else {
        tracing::warn!("audio start failed");
        return 1;
    };
    *INPUT.lock().expect("audio capture mutex poisoned") = Some(input);
    tracing::info!("audio started");
    0
}

/// Captures a short sample window and returns the number of non-silent samples.
#[ffi_export]
pub fn media_audio_probe(duration_ms: u64) -> usize {
    let mut input = match tokio_executor(audio().default_input()) {
        Ok(input) => input,
        Err(_) => return 0,
    };
    let deadline = Instant::now() + Duration::from_millis(duration_ms.clamp(100, 5_000));
    let mut samples = vec![0.0f32; 480];
    let mut non_silent = 0usize;
    while Instant::now() < deadline {
        match input.pop_samples(&mut samples) {
            Ok(Some(count)) => {
                non_silent += samples[..count]
                    .iter()
                    .filter(|sample| sample.abs() > 0.001)
                    .count()
            }
            Ok(None) => thread::sleep(Duration::from_millis(5)),
            Err(_) => return 0,
        }
    }
    non_silent
}

/// Stops microphone capture when it is not owned by a live publisher.
#[ffi_export]
pub fn media_audio_stop() {
    *INPUT.lock().expect("audio capture mutex poisoned") = None;
    tracing::info!("audio stopped");
}

/// Starts recording microphone audio in the Native SDK app-data directory.
#[ffi_export]
pub fn media_recording_start() -> u8 {
    tracing::info!("recording start requested");
    if LOCAL_RECORDING
        .lock()
        .expect("recording mutex poisoned")
        .is_some()
    {
        tracing::warn!("recording start rejected: already recording");
        return 1;
    }
    let input = match tokio_executor(audio().default_input()) {
        Ok(input) => input,
        Err(err) => {
            tracing::warn!("recording input initialization failed: {err:#}");
            return 1;
        }
    };
    let path = media_path("recording.opus");
    let recorder =
        match OggOpusRecorder::create(path.to_str().unwrap_or("/tmp/nufon/recording.opus")) {
            Ok(r) => Arc::new(Mutex::new(r)),
            Err(err) => {
                tracing::warn!(error = %err, "recording file initialization failed");
                return 1;
            }
        };
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let thread_recorder = recorder.clone();
    let peak = Arc::new(Mutex::new(0.0f32));
    let thread_peak = peak.clone();
    let thread = thread::spawn(move || {
        let mut input = input;
        let mut samples = vec![0.0f32; 480];
        while !thread_stop.load(Ordering::Relaxed) {
            match input.pop_samples(&mut samples) {
                Ok(Some(count)) => {
                    let current_peak = samples[..count]
                        .iter()
                        .fold(0.0f32, |peak, sample| peak.max(sample.abs()));
                    let mut recorded_peak =
                        thread_peak.lock().expect("recording peak mutex poisoned");
                    *recorded_peak = recorded_peak.max(current_peak);
                    drop(recorded_peak);
                    let _ = thread_recorder
                        .lock()
                        .expect("recorder mutex poisoned")
                        .push(&samples[..count]);
                    // InputStream can report an underflow with a filled buffer;
                    // do not spin and encode thousands of synthetic frames per
                    // second while waiting for the device callback.
                    thread::sleep(Duration::from_millis(10));
                }
                Ok(None) => thread::sleep(Duration::from_millis(5)),
                Err(_) => break,
            }
        }
    });
    tracing::info!(path = %path.display(), "microphone recording started");
    *LOCAL_RECORDING.lock().expect("recording mutex poisoned") = Some(LocalRecording {
        stop,
        thread: Some(thread),
        recorder,
        peak,
        started: Instant::now(),
    });
    0
}

/// Stops and finalizes the local microphone recording.
#[ffi_export]
pub fn media_recording_stop() -> u8 {
    tracing::info!("recording stop requested");
    let Some(mut recording) = LOCAL_RECORDING
        .lock()
        .expect("recording mutex poisoned")
        .take()
    else {
        tracing::warn!("recording stop rejected: no active recording");
        return 1;
    };
    recording.stop.store(true, Ordering::Relaxed);
    if let Some(thread) = recording.thread.take() {
        let _ = thread.join();
    }
    let peak = *recording
        .peak
        .lock()
        .expect("recording peak mutex poisoned");
    let result = recording
        .recorder
        .lock()
        .expect("recorder mutex poisoned")
        .finish();
    let elapsed_ms = recording.started.elapsed().as_millis();
    LAST_RECORDING_DURATION_MS.store(elapsed_ms as u64, Ordering::Relaxed);
    let packets = recording
        .recorder
        .lock()
        .expect("recorder mutex poisoned")
        .sequence;
    tracing::info!(elapsed_ms, packets, peak, "microphone recording finalized");
    if result.is_err() || peak < 0.001 {
        if let Err(error) = result {
            tracing::warn!(error = %error, "microphone recording finalization failed");
        }
        if peak < 0.001 {
            tracing::warn!(peak, "microphone recording contains no audible samples");
        }
        return 1;
    }
    tracing::info!("recording stop complete");
    0
}

/// Returns the duration of the most recently finalized local recording.
#[ffi_export]
pub fn media_recording_duration_ms() -> u64 {
    LAST_RECORDING_DURATION_MS.load(Ordering::Relaxed)
}

/// Returns whether a microphone source or live publisher is active.
#[ffi_export]
pub fn media_audio_active() -> u8 {
    let input_active = INPUT
        .lock()
        .expect("audio capture mutex poisoned")
        .is_some();
    let live_active = LIVE.lock().expect("live mutex poisoned").is_some();
    let recording_active = LOCAL_RECORDING
        .lock()
        .expect("recording mutex poisoned")
        .is_some();
    let subscribed = SUBSCRIBER
        .lock()
        .expect("subscriber mutex poisoned")
        .is_some();
    u8::from(input_active || live_active || recording_active || subscribed)
}

/// Sets the live audio encode target bitrate in bits per second (Opus VBR).
/// Valid range 8000..=510000; applies to the next live publisher start.
#[ffi_export]
pub fn media_audio_set_bitrate(bitrate: u32) -> u8 {
    if !(8_000..=510_000).contains(&bitrate) {
        tracing::warn!(bitrate, "live audio bitrate rejected: out of range");
        return 1;
    }
    tracing::info!(bitrate, "live audio bitrate set");
    BITRATE.store(bitrate as u64, Ordering::Relaxed);
    0
}

/// Starts an Opus microphone broadcast and returns its iroh-live ticket.
#[ffi_export]
pub fn media_live_start() -> char_p::Box {
    tracing::info!("live publisher start requested");
    let result = tokio_executor(async {
        let input = match INPUT.lock().expect("audio capture mutex poisoned").take() {
            Some(input) => input,
            None => audio().default_input().await?,
        };
        let live = Live::from_env().await?.with_router().spawn();
        let broadcast = LocalBroadcast::new();
        let bitrate = BITRATE.load(Ordering::Relaxed);
        let encoder_config = AudioEncoderConfig::from_preset(AudioFormat::mono_48k(), AudioPreset::Hq).bitrate(bitrate);
        let catalog = OpusEncoder::config_for(&encoder_config);
        let mut renditions = AudioRenditions::empty(MuteSource { inner: input });
        renditions.add_with_callback::<OpusEncoder>(
            format!("audio/opus-{bitrate}"),
            catalog.into(),
            move |_format| OpusEncoder::with_config(encoder_config.clone()),
        );
        broadcast.audio().set_renditions(renditions)?;;
        let broadcast_name = broadcast_name();
        live.publish(&broadcast_name, &broadcast).await?;
        let ticket = LiveTicket::new(live.endpoint().addr(), &broadcast_name).serialize();
        LIVE.lock()
            .expect("live mutex poisoned")
            .replace(LiveSession {
                _live: live,
                _broadcast: broadcast,
            });
        anyhow::Ok(ticket)
    });
    match result {
        Ok(ticket) => {
            tracing::info!(ticket_len = ticket.len(), "live publisher started");
            ticket.try_into().expect("live ticket conversion failed")
        }
        Err(err) => {
            tracing::warn!("failed to start live audio: {err:#}");
            String::new().try_into().expect("empty ticket conversion")
        }
    }
}

/// Stops the live microphone broadcast.
#[ffi_export]
pub fn media_live_stop() {
    tracing::info!("live publisher stop requested");
    let session = LIVE.lock().expect("live mutex poisoned").take();
    if let Some(session) = session {
        tokio_executor(async move { session._live.shutdown().await });
        tracing::info!("live publisher stopped");
    } else {
        tracing::info!("live publisher stop ignored: no active publisher");
    }
}

/// Subscribes to a live ticket and records decoded audio in the app-data directory.
#[ffi_export]
pub fn media_live_subscribe(ticket: char_p::Ref<'_>) -> u8 {
    let ticket_text = ticket.to_str();
    tracing::info!(ticket_len = ticket_text.len(), "live subscriber start requested");
    let Ok(ticket) = LiveTicket::deserialize(ticket_text) else {
        tracing::warn!("live subscriber rejected: invalid ticket");
        return 1;
    };
    let result = tokio_executor(async {
        let path = media_path("received.wav");
        let recorder = Arc::new(Mutex::new(WavRecorder::create(
            path.to_str().unwrap_or("/tmp/nufon/received.wav"),
            AudioFormat::stereo_48k(),
        )?));
        let backend = RecordingBackend {
            recorder: recorder.clone(),
            output: audio().clone(),
        };
        let live = Live::from_env().await?.spawn();
        let subscription = live
            .subscribe(ticket.endpoint, &ticket.broadcast_name)
            .await?;
        let tracks = subscription
            .media(&backend, PlaybackConfig::default())
            .await?;
        if tracks.audio.is_none() {
            anyhow::bail!("live broadcast has no audio track");
        }
        anyhow::Ok((live, subscription, tracks, recorder))
    });
    match result {
        Ok((live, subscription, tracks, recorder)) => {
            tracing::info!("live subscriber connected and recording");
            let previous = SUBSCRIBER
                .lock()
                .expect("subscriber mutex poisoned")
                .replace(Subscriber {
                    _live: live,
                    _subscription: subscription,
                    _tracks: tracks,
                    recording: recorder,
                });
            if let Some(previous) = previous {
                tokio_executor(async move {
                    let Subscriber {
                        _live,
                        _subscription,
                        _tracks,
                        recording: _,
                    } = previous;
                    drop(_tracks);
                    drop(_subscription);
                    _live.shutdown().await;
                });
            }
            0
        }
        Err(err) => {
            tracing::warn!("failed to subscribe to live audio: {err:#}");
            1
        }
    }
}

/// Returns the number of decoded frames written to the subscriber WAV file.
#[ffi_export]
pub fn media_live_recording_samples() -> usize {
    SUBSCRIBER
        .lock()
        .expect("subscriber mutex poisoned")
        .as_ref()
        .map(|subscriber| {
            subscriber
                .recording
                .lock()
                .expect("recorder mutex poisoned")
                .samples
        })
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn ogg_opus_writes_headers_and_audio_page() {
        let path = std::env::temp_dir().join(format!(
            "nufon-test-{}.opus",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut recorder = OggOpusRecorder::create(path.to_str().unwrap()).unwrap();
        recorder.push(&vec![0.1f32; 960]).unwrap();
        recorder.finish().unwrap();
        let data = fs::read(&path).unwrap();
        assert!(data.windows(4).any(|window| window == b"OggS"));
        assert!(data.windows(8).any(|window| window == b"OpusHead"));
        assert!(data.windows(8).any(|window| window == b"OpusTags"));
        let mut reader = PacketReader::new(std::io::Cursor::new(data));
        assert_eq!(
            reader.read_packet().unwrap().unwrap().data,
            b"OpusHead\x01\x01\x38\x01\x80\xbb\x00\x00\x00\x00\x00"
        );
        assert_eq!(
            reader.read_packet().unwrap().unwrap().data,
            b"OpusTags\x05\x00\x00\x00Nufon\x00\x00\x00\x00"
        );
        let packet = reader.read_packet().unwrap().unwrap();
        assert!(packet.data.len() > 2);
        let config = iroh_live::media::config::AudioConfig {
            codec: iroh_live::media::config::AudioCodec::Opus,
            sample_rate: 48_000,
            channel_count: 1,
            bitrate: Some(128_000),
            description: None,
        };
        let mut decoder =
            iroh_live::media::codec::OpusAudioDecoder::new(&config, AudioFormat::mono_48k())
                .unwrap();
        decoder
            .push_packet(iroh_live::media::format::MediaPacket {
                timestamp: Duration::ZERO,
                payload: buf_list::BufList::from(Bytes::from(packet.data)),
                is_keyframe: true,
            })
            .unwrap();
        assert!(decoder.pop_samples().unwrap().is_some());
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn wav_finalize_writes_data_size_and_samples() {
        let path = std::env::temp_dir().join(format!(
            "nufon-test-{}.wav",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut recorder =
            WavRecorder::create(path.to_str().unwrap(), AudioFormat::mono_48k()).unwrap();
        recorder.push(&[0.0, 0.5, -0.5, 0.0]).unwrap();
        recorder.finish().unwrap();
        let data = fs::read(&path).unwrap();
        assert_eq!(&data[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(data[40..44].try_into().unwrap()), 8);
        assert!(data[44..].iter().any(|byte| *byte != 0));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn blob_store_persists_named_recording() {
        let root = std::env::temp_dir().join(format!(
            "nufon-blobs-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let wav = root.join("recording.wav");
        fs::create_dir_all(&root).unwrap();
        fs::write(&wav, b"test recording").unwrap();
        tokio_executor(async {
            let store = FsStore::load(&root).await.unwrap();
            let content = store
                .add_path(&wav)
                .with_named_tag("recording")
                .await
                .unwrap();
            let mut tags = store.tags().list().await.unwrap();
            use n0_future::StreamExt;
            let tag = tags.next().await.unwrap().unwrap();
            assert_eq!(tag.hash, content.hash);
        });
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn blob_ticket_transfers_recording_between_endpoints() {
        let root = std::env::temp_dir().join(format!(
            "nufon-transfer-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let source = root.join("source.wav");
        let target = root.join("target.wav");
        fs::create_dir_all(&root).unwrap();
        fs::write(&source, b"received decoded audio").unwrap();
        tokio_executor(async {
            let provider_endpoint = iroh::Endpoint::bind(iroh::endpoint::presets::N0)
                .await
                .unwrap();
            let provider_store = FsStore::load(root.join("provider")).await.unwrap();
            let content = provider_store
                .add_path(&source)
                .with_named_tag("recording")
                .await
                .unwrap();
            let protocol = BlobsProtocol::new(provider_store.as_ref(), None);
            let router = Router::builder(provider_endpoint.clone())
                .accept(BLOBS_ALPN, protocol)
                .spawn();
            provider_endpoint.online().await;
            let recipient_endpoint = iroh::Endpoint::bind(iroh::endpoint::presets::N0)
                .await
                .unwrap();
            let recipient_store = FsStore::load(root.join("recipient")).await.unwrap();
            recipient_endpoint.online().await;
            let ticket = BlobTicket::new(provider_endpoint.addr(), content.hash, content.format);
            recipient_store
                .downloader(&recipient_endpoint)
                .download(ticket.hash(), Some(ticket.addr().id))
                .await
                .unwrap();
            recipient_store
                .blobs()
                .export(ticket.hash(), &target)
                .await
                .unwrap();
            assert_eq!(fs::read(&source).unwrap(), fs::read(&target).unwrap());
            router.shutdown().await.unwrap();
            provider_endpoint.close().await;
            recipient_endpoint.close().await;
        });
        fs::remove_dir_all(root).unwrap();
    }
}

/// Stores the finalized recipient recording in the local iroh-blobs filesystem store.
/// Returns the BLAKE3 content hash, or an empty string on failure.
#[ffi_export]
pub fn media_live_recording_store() -> char_p::Box {
    tracing::info!("recording blob store requested");
    // Reuse the previous provider's live/store/router instead of reopening:
    // a second FsStore::load on the same "blobs" directory deadlocks on
    // blobs.db while the previous store is still shutting down, which made
    // every store after the first hang forever.
    let existing = BLOB_PROVIDER
        .lock()
        .expect("blob provider mutex poisoned")
        .take();
    let result = tokio_executor(async move {
        let (live, store, router) = match existing {
            Some(BlobProvider {
                _live: live,
                _store: store,
                _router: router,
            }) => (live, store, router),
            None => {
                let live = Live::from_env().await?.spawn();
                let store = FsStore::load(media_dir().join("blobs")).await?;
                let protocol = BlobsProtocol::new(store.as_ref(), None);
                let router = Router::builder(live.endpoint().clone())
                    .accept(BLOBS_ALPN, protocol)
                    .spawn();
                (live, store, router)
            }
        };
        let local = media_path("recording.opus");
        let received = media_path("received.wav");
        let recording_path = if local.exists() { local } else { received };
        anyhow::ensure!(recording_path.exists(), "no finalized recording exists");
        anyhow::ensure!(
            fs::metadata(&recording_path)?.len() > 0,
            "recording is empty"
        );
        let content = store.add_path(recording_path).await?;
        let recording_tag = format!("recording-{}", content.hash);
        store.tags().set(&recording_tag, content.hash).await?;
        let ticket = BlobTicket::new(live.endpoint().addr(), content.hash, content.format);
        BLOB_PROVIDER
            .lock()
            .expect("blob provider mutex poisoned")
            .replace(BlobProvider {
                _live: live,
                _store: store,
                _router: router,
            });
        anyhow::Ok(ticket.to_string())
    });
    match result {
        Ok(hash) => {
            tracing::info!(ticket_len = hash.len(), "recording blob stored");
            hash.try_into().expect("blob hash conversion failed")
        }
        Err(err) => {
            tracing::warn!("failed to store recording blob: {err:#}");
            String::new()
                .try_into()
                .expect("empty blob hash conversion")
        }
    }
}

/// Fetches a BlobTicket into the Native SDK app-data directory.
/// Returns `0` on success and `1` on failure.
#[ffi_export]
pub fn media_blob_fetch(ticket: char_p::Ref<'_>) -> u8 {
    let ticket_text = ticket.to_str();
    tracing::info!(ticket_len = ticket_text.len(), "recording blob fetch requested");
    let Ok(ticket) = ticket_text.parse::<BlobTicket>() else {
        tracing::warn!("recording blob fetch rejected: invalid ticket");
        return 1;
    };
    match ensure_fetched(&ticket) {
        Ok(_) => {
            tracing::info!("recording blob fetch complete");
            0
        }
        Err(err) => {
            tracing::warn!("failed to fetch recording blob: {err:#}");
            1
        }
    }
}

/// Immediately stops inbound live audio, playback, and microphone capture.
#[ffi_export]
pub fn media_emergency_stop() {
    media_recording_stop_playback();
    media_live_unsubscribe();
    media_live_stop();
    media_audio_stop();
}

/// Stops all media resources during application shutdown.
#[ffi_export]
pub fn media_shutdown() {
    media_recording_stop_playback();
    let _ = media_recording_stop();
    media_live_unsubscribe();
    media_live_stop();
    BLOB_PROVIDER
        .lock()
        .expect("blob provider mutex poisoned")
        .take();
    *INPUT.lock().expect("audio capture mutex poisoned") = None;
}

/// Stops the live audio subscription and finalizes its WAV recording.
#[ffi_export]
pub fn media_live_unsubscribe() {
    tracing::info!("live subscriber stop requested");
    if let Some(subscriber) = SUBSCRIBER.lock().expect("subscriber mutex poisoned").take() {
        let Subscriber {
            _live,
            _subscription,
            _tracks,
            recording,
        } = subscriber;
        // Stop the decoder/output thread before rewriting the WAV header.
        drop(_tracks);
        drop(_subscription);
        tokio_executor(async move { _live.shutdown().await });
        let mut recorder = recording.lock().expect("recorder mutex poisoned");
        let _ = recorder.finish();
        tracing::info!(samples = recorder.samples, "live audio recording finalized");
    } else {
        tracing::info!("live subscriber stop ignored: no active subscriber");
    }
}
