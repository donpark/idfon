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

use moq_media::{
    audio_file::AudioFile,
    publish::AudioSource,
    subscribe::RemoteBroadcast,
};
use moq_audio::decode::{Config as AudioDecodeConfig, Consumer as AudioConsumer};
use moq_audio::Format;
use moq_audio::encode::Options as AudioOptions;
use iroh_live::{ticket::LiveTicket, Live};
use iroh::{Endpoint, EndpointAddr, EndpointId};
use iroh::protocol::ProtocolHandler as _;

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
    /// file does (the publisher stays reachable until stopped). With
    /// `relay` set, the endpoint uses n0's public relays as a fallback
    /// transport; without it, subscribers must reach the endpoint directly
    /// (loopback/LAN) and no relay traffic is generated at all.
    pub fn start(
        path: &Path,
        loop_playback: bool,
        name: &str,
        relay: bool,
    ) -> anyhow::Result<(Self, String)> {
        // The daemon dispatches on tokio workers; runtime creation and
        // block_on must happen on a fresh thread (see blob.rs).
        let path = path.to_path_buf();
        let name = name.to_string();
        let handle = std::thread::spawn(move || {
            Self::start_blocking(path, loop_playback, name, relay)
        });
        handle.join().map_err(|_| anyhow::anyhow!("publisher thread panicked"))?
    }

    fn start_blocking(
        path: PathBuf,
        loop_playback: bool,
        name: String,
        relay: bool,
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
            let endpoint = match build_endpoint(relay).await {
                Ok(endpoint) => endpoint,
                Err(err) => return fail(format!("endpoint: {err:#}")),
            };
            let live = Arc::new(Live::builder(endpoint).with_router().spawn());
            let broadcast = match live.publish(&name) {
                Ok(broadcast) => broadcast,
                Err(err) => return fail(format!("publish: {err:#}")),
            };
            let source = match AudioFile::open(&path, loop_playback) {
                Ok(source) => source,
                Err(err) => return fail(format!("audio file source: {err:#}")),
            };
            broadcast.audio().set_with(
                AudioSource::Frames {
                    input: source.input(),
                    frames: source.into_stream(),
                },
                AudioOptions::default(),
            );
            let ticket = LiveTicket::new(live.endpoint().id(), &name).serialize();
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
    /// Time from capture start to an established subscribe session.
    pub subscribe_ms: u64,
    /// Time from capture start to the first packet (startup latency;
    /// UX-facing "how long until audio flows").
    pub startup_ms: u64,
    /// Largest interval between consecutive packets (a stall would show up
    /// here even when the average jitter is tiny).
    pub max_gap_ms: u64,
    /// Arrival gaps longer than 100 ms (would drain any small play buffer).
    pub stalls_over_100ms: u32,
    /// Estimated missing packets from pts-timeline holes.
    pub missing_packets: u32,
    /// Smallest prebuffer that would have played the whole capture without
    /// an underrun, given the observed arrival schedule (ms).
    pub prebuffer_ms: u64,
}

pub(crate) async fn build_endpoint(relay: bool) -> anyhow::Result<Endpoint> {
    // N0 preset: n0 public relays as fallback transport + DNS discovery.
    // N0DisableRelay: no relay transport at all — direct connections only
    // (loopback/LAN tests, and keeps traffic off the rate-limited public
    // relays); DNS address lookup still resolves direct addresses.
    let builder = if relay {
        Endpoint::builder(iroh::endpoint::presets::N0)
    } else {
        Endpoint::builder(iroh::endpoint::presets::N0DisableRelay)
    };
    Ok(builder.bind().await?)
}

/// Subscribes to a live ticket and records up to `seconds` of audio to a
/// 16-bit PCM mono 48 kHz WAV. Retries the initial subscribe: the publisher
/// may not have announced its catalog yet.
pub fn listen_to_wav(
    ticket: &str,
    out: &Path,
    seconds: u64,
    relay: bool,
) -> anyhow::Result<ListenStats> {
    let ticket = ticket.to_string();
    let out = out.to_path_buf();
    let handle = std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(listen_wav(&ticket, &out, seconds, relay))
    });
    handle.join().map_err(|_| anyhow::anyhow!("listener thread panicked"))?
}

/// Dials `peer_addr` (a serde_json-serialized iroh `EndpointAddr`, as stored
/// in the daemon's peer registry) and publishes `path`'s audio on the
/// session only. Unlike [`LivePublisher`] there is no ticket: the session
/// is the capability, so no third party can subscribe. Blocks until the
/// peer hangs up (its subscribe session closes) or `seconds` elapses
/// (`None` = wait for hangup). Returns wall-clock time held open.
pub fn stream_to_peer(
    path: &Path,
    loop_playback: bool,
    peer_addr: &str,
    seconds: Option<u64>,
    relay: bool,
) -> anyhow::Result<u64> {
    let path = path.to_path_buf();
    let peer_addr = peer_addr.to_string();
    let handle = std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(stream_peer(&path, loop_playback, &peer_addr, seconds, relay))
    });
    handle.join().map_err(|_| anyhow::anyhow!("caller thread panicked"))?
}

async fn stream_peer(
    path: &Path,
    loop_playback: bool,
    peer_addr: &str,
    seconds: Option<u64>,
    relay: bool,
) -> anyhow::Result<u64> {
    let addr: EndpointAddr = serde_json::from_str(peer_addr)
        .map_err(|err| anyhow::anyhow!("invalid peer endpoint address: {err}"))?;
    let endpoint = build_endpoint(relay).await?;
    let live = Live::builder(endpoint).with_router().spawn();
    let call_path = iroh_live::Call::path(live.endpoint().id());
    let broadcast = live.publish(&call_path)?;
    let source = AudioFile::open(path, loop_playback)?;
    broadcast.audio().set_with(
        AudioSource::Frames {
            input: source.input(),
            frames: source.into_stream(),
        },
        AudioOptions::default(),
    );
    let call = iroh_live::Call::dial(&live, addr)
        .await
        .map_err(|err| anyhow::anyhow!("dial call: {err}"))?;
    let base = Instant::now();
    // The receiver controls the call length: it hangs up when its capture
    // window ends, which closes the session and releases us. `seconds` is a
    // safety cap for callers nobody hangs up on.
    match seconds {
        Some(cap) => tokio::time::sleep(Duration::from_secs(cap)).await,
        None => {
            call.closed().await;
        }
    }
    let held_ms = base.elapsed().as_millis() as u64;
    call.close();
    live.shutdown().await;
    Ok(held_ms)
}

/// Waits up to `wait` seconds for an inbound 1:1 call on the daemon's
/// transport endpoint (the MoQ ALPN side-channel is registered here for the
/// duration), accepts it, and records the caller's audio to a WAV file,
/// ending when the caller's broadcast ends or `seconds` elapse. With `from`
/// set, calls from any other endpoint are rejected.
pub fn answer_to_wav(
    transport: std::sync::Arc<idfon_core::transport::IrohTransport>,
    out: &Path,
    seconds: u64,
    wait: u64,
    from: Option<&str>,
) -> anyhow::Result<ListenStats> {
    let out = out.to_path_buf();
    let from = from.map(str::to_string);
    let handle = std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(answer_wav(&transport, &out, seconds, wait, from.as_deref()))
    });
    handle.join().map_err(|_| anyhow::anyhow!("answer thread panicked"))?
}

async fn answer_wav(
    transport: &idfon_core::transport::IrohTransport,
    out: &Path,
    seconds: u64,
    wait: u64,
    from: Option<&str>,
) -> anyhow::Result<ListenStats> {
    let from_id: Option<EndpointId> = match from {
        Some(id) => Some(id.parse().map_err(|err| anyhow::anyhow!("invalid --from endpoint id: {err}"))?),
        None => None,
    };
    // Mount the current MoQ handler on the daemon endpoint and accept a current
    // iroh-live call session.
    let moq = iroh_live::moq::Moq::new(transport.endpoint().clone());
    let handler = moq.protocol_handler();
    let (tx, mut rx) = tokio::sync::mpsc::channel::<iroh::endpoint::Connection>(8);
    let _side = transport.add_side_channel(iroh_live::moq::ALPN, tx);
    tokio::spawn(async move {
        while let Some(connection) = rx.recv().await {
            let handler = handler.clone();
            tokio::spawn(async move {
                let _ = handler.accept(connection).await;
            });
        }
    });
    let mut incoming = moq.incoming_sessions();
    let session = tokio::time::timeout(Duration::from_secs(wait), async {
        let Some(call) = incoming.next().await else {
            anyhow::bail!("live transport shut down");
        };
        if let Some(want) = from_id {
            if call.remote_id() != want {
                anyhow::bail!("incoming call is from an unexpected endpoint");
            }
        }
        Ok::<_, anyhow::Error>(call)
    })
    .await
    .map_err(|_| anyhow::anyhow!("no incoming call within {wait}s"))??;
    let call = iroh_live::Call::accept(session)
        .await
        .map_err(|err| anyhow::anyhow!("accept call: {err}"))?;
    let remote = call.remote().clone();
    let stats = record_remote(&remote, out, seconds, 0, true).await?;
    call.close();
    drop(_side);
    Ok(stats)
}

/// Records `broadcast`'s best audio rendition to a 16-bit PCM mono 48 kHz
/// WAV, ending when the broadcast ends or `seconds` elapse. Shared by the
/// ticket path and the 1:1 answer path.
async fn record_remote(
    broadcast: &RemoteBroadcast,
    out: &Path,
    seconds: u64,
    subscribe_ms: u64,
    hangup_ends: bool,
) -> anyhow::Result<ListenStats> {
    let base = Instant::now();
    let catalog = broadcast.catalog();
    let audio = catalog
        .first_audio()
        .ok_or_else(|| anyhow::anyhow!("broadcast has no audio track"))?;
    let config = catalog
        .audio()
        .get(audio)
        .ok_or_else(|| anyhow::anyhow!("audio catalog entry disappeared"))?;
    let mut decode_config = AudioDecodeConfig::new();
    decode_config.format = Format::F32;
    decode_config.sample_rate = Some(48_000);
    decode_config.channels = Some(1);
    let mut decoder = AudioConsumer::new(
        broadcast.consumer(), config, audio, decode_config,
    ).await?;

    let start = Instant::now();
    let wall_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let mut samples: Vec<f32> = Vec::new();
    let mut arrivals: Vec<u128> = Vec::new();
    let mut pts: Vec<u128> = Vec::new();

    while start.elapsed() < Duration::from_secs(seconds) {
        let frame = match decoder.read().await {
            Ok(Some(frame)) => frame,
            Ok(None) => break,
            // On a 1:1 call the peer hanging up is a normal end, not an error.
            Err(_) if hangup_ends => break,
            Err(err) => return Err(err.into()),
        };
        arrivals.push(base.elapsed().as_millis());
        pts.push(frame.timestamp.as_millis());
        for chunk in frame.data.chunks_exact(4) {
            samples.push(f32::from_le_bytes(chunk.try_into().unwrap()));
        }
    }

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

    // UX metrics from the arrival schedule and publisher timeline.
    let max_gap_ms = intervals.iter().max().copied().unwrap_or(0) as u64;
    let stalls = intervals.iter().filter(|i| **i > 100).count() as u32;

    // Missing packets: pts deltas much larger than the median pacing step.
    let mut pts_deltas: Vec<u128> = pts.windows(2).map(|w| w[1] - w[0]).collect();
    pts_deltas.sort_unstable();
    let step = pts_deltas.get(pts_deltas.len() / 2).copied().unwrap_or(0);
    let missing = if step > 0 {
        pts.windows(2)
            .filter(|w| w[1] > w[0] + step + step / 2)
            .map(|w| ((w[1] - w[0]) as f64 / step as f64).round() as u32 - 1)
            .sum::<u32>()
    } else {
        0
    };

    // Minimum prebuffer to play the capture without an underrun: replay
    // starts when the first packet arrives and advances at the publisher's
    // pacing; any packet arriving after its play time forces a stall.
    let a0 = arrivals.first().copied().unwrap_or(0);
    let p0 = pts.first().copied().unwrap_or(0);
    let prebuffer = arrivals
        .iter()
        .zip(pts.iter())
        .map(|(a, p)| a.saturating_sub(a0 + p.saturating_sub(p0)))
        .max()
        .unwrap_or(0) as u64;

    Ok(ListenStats {
        duration_ms: samples.len() as u64 / 48,
        packets: arrivals.len(),
        arrival_jitter_ms: (jitter * 10.0).round() / 10.0,
        wall_ms,
        subscribe_ms,
        startup_ms: arrivals.first().copied().unwrap_or(0).saturating_sub(subscribe_ms as u128) as u64,
        max_gap_ms,
        stalls_over_100ms: stalls,
        missing_packets: missing,
        prebuffer_ms: prebuffer,
    })
}

async fn listen_wav(
    ticket: &str,
    out: &PathBuf,
    seconds: u64,
    relay: bool,
) -> anyhow::Result<ListenStats> {
    let parsed: LiveTicket = ticket.parse()?;
    let remote_addr = parsed.endpoint.clone();
    let name = parsed.broadcast_name.clone();
    let local_endpoint = build_endpoint(relay).await?;
    let live = Live::builder(local_endpoint).spawn();
    let base = Instant::now();
    let mut last_err = String::new();
    // A subscribe to a broadcast that never got announced blocks forever
    // inside iroh, so every attempt is bounded by a timeout; the outer
    // retries cover a publisher whose catalog announce hasn't landed yet.
    const SUBSCRIBE_ATTEMPTS: u32 = 3;
    const SUBSCRIBE_TIMEOUT: Duration = Duration::from_secs(8);
    let sub = {
        let mut result = None;
        for _attempt in 0..SUBSCRIBE_ATTEMPTS {
            match tokio::time::timeout(
                SUBSCRIBE_TIMEOUT,
                live.subscribe(remote_addr.clone(), &name),
            )
            .await
            {
                Ok(Ok(sub)) => {
                    result = Some(sub);
                    break;
                }
                Ok(Err(e)) => {
                    last_err = format!("{e:#}");
                }
                Err(_) => {
                    last_err =
                        "timed out waiting for the broadcast to be announced".into();
                }
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        result.ok_or_else(|| anyhow::anyhow!("subscribe failed after retries: {last_err}"))?
    };
    let subscribe_ms = base.elapsed().as_millis() as u64;
    let stats = record_remote(sub.broadcast(), out, seconds, subscribe_ms, false).await?;
    drop(sub);
    let _ = live.shutdown().await;
    Ok(stats)
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
        let dir = std::env::temp_dir().join("idfon-live-wav-test");
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
