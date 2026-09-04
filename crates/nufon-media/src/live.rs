//! Headless live-audio publish/subscribe without a capture device.
//!
//! The publisher streams a media file (symphonia decodes, Opus encodes) over
//! iroh-live; the subscriber decodes a remote broadcast to a 48 kHz mono WAV
//! plus per-packet arrival timings. Both are sync entry points safe to call
//! from non-async contexts: they run their async work on a fresh thread with
//! a local runtime, like the daemon's blob path.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use iroh_live::media::{
    audio_file_source::AudioFileSource,
    codec::{self, OpusAudioDecoder},
    config::AudioConfig,
    format::{AudioFormat, AudioPreset, Quality},
    publish::LocalBroadcast,
    traits::AudioDecoder,
    transport::PacketSource,
};
use iroh_live::{ticket::LiveTicket, Live};

/// A running file-source publisher. Holds the live endpoint, router, and
/// broadcast; the tokio runtime is owned by this struct (a runtime dropped
/// after publishing tears down the endpoint/router tasks and leaves the
/// broadcast dead). Call [`LivePublisher::stop`] for graceful shutdown.
pub struct LivePublisher {
    runtime: tokio::runtime::Runtime,
    task: tokio::task::JoinHandle<()>,
    live: Arc<Live>,
}

impl LivePublisher {
    /// Publishes `path` (WAV/MP3/FLAC) as a live broadcast. `loop_playback`
    /// repeats the file indefinitely; otherwise the broadcast ends when the
    /// file does (the publisher stays reachable until stopped).
    pub fn start(path: &Path, loop_playback: bool, name: &str) -> anyhow::Result<(Self, String)> {
        // The daemon dispatches on tokio workers; runtime creation and
        // block_on must happen on a fresh thread (see blob.rs).
        let path = path.to_path_buf();
        let name = name.to_string();
        let handle = std::thread::spawn(move || Self::start_blocking(path, loop_playback, name));
        handle.join().map_err(|_| anyhow::anyhow!("publisher thread panicked"))?
    }

    fn start_blocking(
        path: PathBuf,
        loop_playback: bool,
        name: String,
    ) -> anyhow::Result<(Self, String)> {
        let runtime = tokio::runtime::Runtime::new()?;
        let (tx, rx) = std::sync::mpsc::channel();
        // The task owns Live AND LocalBroadcast and holds them across the
        // pending().await below: dropping the broadcast tears down its
        // producer/catalog, so it must outlive the publish call.
        let task = runtime.spawn(async move {
            let fail = |err: String| {
                let _ = tx.send(Err(err));
            };
            let live = match Live::from_env().await {
                Ok(builder) => Arc::new(builder.with_router().spawn()),
                Err(err) => return fail(format!("{err:#}")),
            };
            let broadcast = LocalBroadcast::new();
            let source = match AudioFileSource::new(&path, loop_playback) {
                Ok(source) => source,
                Err(err) => return fail(format!("audio file source: {err:#}")),
            };
            if let Err(err) =
                broadcast.audio().set(source, codec::AudioCodec::Opus, [AudioPreset::Hq])
            {
                return fail(format!("audio setup: {err:#}"));
            }
            if let Err(err) = live.publish(&name, &broadcast).await {
                return fail(format!("publish: {err:#}"));
            }
            let ticket = LiveTicket::new(live.endpoint().addr(), &name).serialize();
            let _ = tx.send(Ok((live.clone(), ticket)));
            // Hold the broadcast open until stop()/shutdown.
            std::future::pending::<()>().await;
        });
        let (live, ticket) = rx
            .recv()
            .map_err(|_| anyhow::anyhow!("publisher task died before answering"))?
            .map_err(|err| anyhow::anyhow!(err))?;
        Ok((Self { runtime, task, live }, ticket))
    }

    /// Graceful shutdown: keeps the endpoint alive until the router drains.
    pub fn stop(self) {
        let _ = std::thread::spawn(move || {
            let live = self.live.clone();
            let _ = self
                .runtime
                .block_on(async move { live.shutdown().await });
            self.task.abort();
            self.runtime.shutdown_timeout(Duration::from_secs(1));
        })
        .join();
    }
}


/// Result of a [`listen_to_wav`] capture.
#[derive(Debug, Clone)]
pub struct ListenStats {
    /// Decoded audio duration in milliseconds.
    pub duration_ms: u64,
    /// Encoded packets received.
    pub packets: usize,
    /// Standard deviation of packet-arrival intervals (wall clock).
    pub arrival_jitter_ms: f64,
    /// Wall-clock (ms since epoch) when capture started, for latency analysis.
    pub wall_ms: u128,
}

/// Subscribes to a live ticket and records up to `seconds` of audio to a
/// 16-bit PCM mono 48 kHz WAV. Retries the initial subscribe: the publisher
/// may not have announced its catalog yet.
pub fn listen_to_wav(ticket: &str, out: &Path, seconds: u64) -> anyhow::Result<ListenStats> {
    let ticket = ticket.to_string();
    let out = out.to_path_buf();
    let handle = std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(listen_wav(&ticket, &out, seconds))
    });
    handle.join().map_err(|_| anyhow::anyhow!("listener thread panicked"))?
}

async fn listen_wav(ticket: &str, out: &PathBuf, seconds: u64) -> anyhow::Result<ListenStats> {
    let parsed: LiveTicket = ticket.parse()?;
    let endpoint = parsed.endpoint.clone();
    let name = parsed.broadcast_name.clone();
    let live = Live::from_env().await?.spawn();
    let mut last_err = String::new();
    let sub = {
        let mut result = None;
        for _attempt in 0..5 {
            match live.subscribe(endpoint.clone(), &name).await {
                Ok(sub) => {
                    result = Some(sub);
                    break;
                }
                Err(e) => {
                    last_err = format!("{e:#}");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        }
        result.ok_or_else(|| anyhow::anyhow!("subscribe failed after retries: {last_err}"))?
    };
    let audio = sub
        .broadcast()
        .catalog()
        .select_audio_rendition(Quality::Highest)?;
    let (mut source, config) = sub.broadcast().raw_audio_track(&audio)?;

    let config: AudioConfig = config.into();
    let mut decoder = OpusAudioDecoder::new(
        &config,
        AudioFormat::mono_48k(),
    )?;

    let start = Instant::now();
    let wall_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let mut samples: Vec<f32> = Vec::new();
    let mut arrivals: Vec<u128> = Vec::new();

    while start.elapsed() < Duration::from_secs(seconds) {
        let Some(pkt) = source.read().await? else { break };
        arrivals.push(start.elapsed().as_millis());
        if decoder.push_packet(pkt).is_err() {
            continue;
        }
        while let Some(buf) = decoder.pop_samples()? {
            samples.extend_from_slice(buf);
        }
    }
    drop(sub);
    let _ = live.shutdown().await;

    write_wav(out, &samples)?;
    let intervals: Vec<u128> = arrivals.windows(2).map(|w| w[1] - w[0]).collect();
    let jitter = if intervals.len() > 1 {
        let mean = intervals.iter().sum::<u128>() as f64 / intervals.len() as f64;
        (intervals
            .iter()
            .map(|i| (*i as f64 - mean).powi(2))
            .sum::<f64>()
            / intervals.len() as f64)
            .sqrt()
    } else {
        0.0
    };
    Ok(ListenStats {
        duration_ms: samples.len() as u64 / 48,
        packets: arrivals.len(),
        arrival_jitter_ms: (jitter * 10.0).round() / 10.0,
        wall_ms,
    })
}

/// Minimal 16-bit PCM mono 48 kHz WAV writer.
fn write_wav(path: &Path, samples: &[f32]) -> anyhow::Result<()> {
    use std::io::Write;
    let mut file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let data_len = (samples.len() * 2) as u32;
    file.write_all(b"RIFF")?;
    file.write_all(&(36 + data_len).to_le_bytes())?;
    file.write_all(b"WAVEfmt ")?;
    file.write_all(&16u32.to_le_bytes())?;
    file.write_all(&1u16.to_le_bytes())?; // PCM
    file.write_all(&1u16.to_le_bytes())?; // mono
    file.write_all(&48000u32.to_le_bytes())?;
    file.write_all(&96000u32.to_le_bytes())?;
    file.write_all(&2u16.to_le_bytes())?;
    file.write_all(&16u16.to_le_bytes())?;
    file.write_all(b"data")?;
    file.write_all(&data_len.to_le_bytes())?;
    for s in samples {
        file.write_all(&((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_header_is_wellformed() {
        let dir = std::env::temp_dir().join("nufon-live-wav-test");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("out.wav");
        write_wav(&path, &[0.0, 0.5, -0.5]).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(bytes.len(), 44 + 6);
        // sample count from the data header
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 6);
    }

    #[test]
    fn jitter_is_zero_for_perfect_pacing() {
        // mirrors the interval math in listen_wav
        let arrivals = vec![0u128, 20, 40, 60];
        let intervals: Vec<u128> = arrivals.windows(2).map(|w| w[1] - w[0]).collect();
        let mean = intervals.iter().sum::<u128>() as f64 / intervals.len() as f64;
        let jitter = (intervals
            .iter()
            .map(|i| (*i as f64 - mean).powi(2))
            .sum::<f64>()
            / intervals.len() as f64)
            .sqrt();
        assert!(jitter.abs() < 1e-9);
    }
}
