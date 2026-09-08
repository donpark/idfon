//! Headless live-video publish/subscribe without a capture device.
//!
//! The publisher imports a video file (fMP4/MKV/TS/FLV/H.264 via moq-mux),
//! decodes it to frames, and simulcasts it as multiple H.264 renditions over
//! iroh-live so the subscriber can pick the rendition that fits its network
//! (receiver-driven quality selection; auto rendition switching arrives with
//! the GUI's decoded-video path). The subscriber records the selected
//! rendition's encoded packets to an Annex B `.h264` file playable with
//! ffplay/mpv.
//!
//! Sync entry points like [`crate::live`]: async work runs on a fresh thread
//! with a local runtime (the daemon's blob path discipline).

use std::path::{Path, PathBuf};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use bytes::Buf;
use moq_mux::import::FramedFormat;
use iroh_live::media::{
    codec::{self, H264VideoDecoder},
    config::{self, VideoConfig},
    format::{DecodeConfig, PixelFormat, VideoFormat, VideoFrame},
    publish::{LocalBroadcast, VideoInput},
    subscribe::RemoteBroadcast,
    traits::{VideoDecoder, VideoSource},
    transport::{MoqPacketSource, PacketSource},
};
use iroh::protocol::ProtocolHandler as _;
use iroh::{EndpointAddr, EndpointId};
use iroh_live::ticket::LiveTicket;
use iroh_live::Live;

use crate::live::build_endpoint;

// Re-exported for callers (daemon/CLI) building preset ladders and quality
// selections without depending on iroh-live directly.
pub use iroh_live::media::format::{Quality, VideoPreset};

/// How long [`VideoFileSource::pop_frame`] waits for the decode task before
/// reporting "no frame yet" (the encode pipeline backs off 2 ms and retries).
const FRAME_WAIT: Duration = Duration::from_millis(200);

/// Channel capacity between the decode task and the encode pipelines
/// (bounded so a slow encoder set applies backpressure to the decode loop).
const FRAME_QUEUE: usize = 8;

/// Detects the import format from the file extension.
fn detect_format(path: &Path) -> anyhow::Result<FramedFormat> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();
    Ok(match ext.as_str() {
        // moq-mux's fmp4 importer parses both fragmented (CMAF) and plain
        // MP4s with a readable moov; exotic profiles may still fail.
        "mp4" | "m4v" | "mov" | "cmfv" => FramedFormat::Fmp4,
        "mkv" | "webm" => FramedFormat::Mkv,
        "ts" | "m2ts" | "mts" => FramedFormat::Ts,
        "flv" => FramedFormat::Flv,
        "h264" | "avc" | "avc3" | "264" => FramedFormat::Avc3,
        other => anyhow::bail!(
            "unsupported video extension .{other} (supported: mp4, mkv, webm, ts, flv, h264)"
        ),
    })
}

/// One imported video file: encoded packets replaying from an in-memory
/// broadcast plus the catalog config describing them.
///
/// The importer must be held for the stream's lifetime: dropping it publishes
/// a catalog without its renditions (moq-mux's `Import::drop` removes them),
/// which would make the broadcast look empty to subscribers.
struct VideoImport {
    source: MoqPacketSource,
    config: VideoConfig,
    _import: moq_mux::container::fmp4::Import,
}

/// Imports `path` into an in-memory broadcast and opens a packet reader on
/// its (first) video rendition. Must run on a tokio runtime (moq consumers
/// are async).
///
/// fMP4 imports tolerate a malformed trailing fragment (moq-mux's own import
/// tests ignore it): earlier fragments still land in the tracks.
///
/// ponytail: the whole file is imported into memory before replay starts;
/// fine for clips, switch to the incremental Stream importer + disk-backed
/// tracks if multi-GB files matter.
async fn import_file(path: &Path) -> anyhow::Result<VideoImport> {
    let format = detect_format(path)?;
    let data = std::fs::read(path)
        .map_err(|err| anyhow::anyhow!("cannot read {}: {err}", path.display()))?;
    let mut producer = moq_lite::Broadcast::default().produce();
    let catalog = moq_mux::catalog::Producer::new(&mut producer)
        .map_err(|err| anyhow::anyhow!("catalog producer: {err}"))?;
    if !matches!(format, FramedFormat::Fmp4) {
        // Only the fMP4 path is wired up; MKV/TS/FLV/H.264 elementary
        // imports would follow the same shape once tested.
        anyhow::bail!("only fragmented MP4 video files are supported yet");
    }
    let mut buf = bytes::BytesMut::from(data.as_slice());
    let import = {
        // Direct fmp4 import: fragment-by-fragment, tolerant of a bad tail.
        let mut import = moq_mux::container::fmp4::Import::new(producer.clone(), catalog.clone());
        // Ignore a malformed trailing fragment: earlier fragments are
        // already in the tracks (moq-mux's own import tests do the same).
        let _ = import.decode(&mut buf);
        // Close every track's open group so consumers observe the data.
        let _ = import.finish();
        // Hold the importer: dropping it would strip the renditions from
        // the catalog (see VideoImport).
        import
    };

    // Read back through the consumer side exactly like a remote subscription:
    // the consumer-side catalog parses the catalog track and carries each
    // rendition's container framing, which the packet reader needs to split
    // CMAF fragments into individual samples.
    let consumer = producer.consume();
    let remote = RemoteBroadcast::new("import", consumer.clone())
        .await
        .map_err(|err| anyhow::anyhow!("imported broadcast: {err:#}"))?;
    // video_ready resolves once the consumer-side catalog has a video track.
    if tokio::time::timeout(Duration::from_secs(5), remote.video_ready())
        .await
        .is_err()
    {
        anyhow::bail!("no video catalog written for {}", path.display());
    }
    let catalog = remote.catalog();
    let rendition = catalog
        .select_video_rendition(Quality::Highest)
        .map_err(|err| anyhow::anyhow!("no video track in {}: {err}", path.display()))?;
    let hang_config = catalog
        .video
        .renditions
        .get(&rendition)
        .ok_or_else(|| anyhow::anyhow!("video rendition config missing"))?
        .clone();
    let track_consumer =
        consumer.subscribe_track(&moq_lite::Track::new(&rendition).with_priority(1))?;
    let container = moq_mux::catalog::hang::Container::try_from(&hang_config.container)?;
    let source = MoqPacketSource::new(moq_mux::container::Consumer::new(
        track_consumer,
        container,
    ));
    Ok(VideoImport {
        source,
        config: hang_config.into(),
        _import: import,
    })
}

/// A [`VideoSource`] fed by a decode task over a bounded channel.
struct VideoFileSource {
    name: String,
    format: VideoFormat,
    rx: mpsc::Receiver<VideoFrame>,
}

impl VideoSource for VideoFileSource {
    fn name(&self) -> &str {
        &self.name
    }

    fn format(&self) -> VideoFormat {
        self.format.clone()
    }

    fn start(&mut self) -> anyhow::Result<()> {
        Ok(())
    }

    fn stop(&mut self) -> anyhow::Result<()> {
        Ok(())
    }

    fn pop_frame(&mut self) -> anyhow::Result<Option<VideoFrame>> {
        match self.rx.recv_timeout(FRAME_WAIT) {
            Ok(frame) => Ok(Some(frame)),
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(anyhow::anyhow!("video ended")),
        }
    }
}

/// Decodes imported packets into frames and forwards them to the encode
/// pipelines. Exits when the import ends or the encoders go away.
async fn decode_loop(
    mut source: MoqPacketSource,
    config: VideoConfig,
    tx: mpsc::SyncSender<VideoFrame>,
) {
    let mut decoder = match H264VideoDecoder::new(&config, &DecodeConfig::default()) {
        Ok(decoder) => decoder,
        Err(err) => {
            eprintln!("video decoder init failed: {err:#}");
            return;
        }
    };
    loop {
        match source.read().await {
            Ok(Some(packet)) => {
                if decoder.push_packet(packet).is_err() {
                    continue;
                }
                while let Ok(Some(frame)) = decoder.pop_frame() {
                    if tx.send(frame).is_err() {
                        return;
                    }
                }
            }
            // End of file: drop the sender so pop_frame reports the end.
            // End of file: drop the sender so the encode pipelines end.
            Ok(None) | Err(_) => return,
        }
    }
}

/// Builds a broadcast that simulcasts `path`'s video as H.264 renditions.
/// The returned `VideoImport` must stay alive for the stream's lifetime
/// (dropping it strips the renditions from the catalog).
///
/// `rx` is the receiving end of the frame channel the caller wires to
/// [`decode_loop`] (spawned separately with the import's source/config).
async fn build_video_broadcast(
    path: &Path,
    presets: Vec<VideoPreset>,
    rx: mpsc::Receiver<VideoFrame>,
) -> anyhow::Result<(LocalBroadcast, VideoImport)> {
    let import = import_file(path).await?;
    // Renditions above the source resolution would upscale; drop
    // them but always keep at least the smallest preset.
    let height = import.config.coded_height.unwrap_or(u32::MAX);
    let mut presets = presets;
    presets.retain(|preset| preset.height() <= height);
    if presets.is_empty() {
        presets = [VideoPreset::P180].to_vec();
    }
    let format = VideoFormat {
        // DecodeConfig::default() outputs RGBA; match it.
        pixel_format: PixelFormat::Rgba,
        dimensions: [
            import.config.coded_width.unwrap_or(640),
            import.config.coded_height.unwrap_or(360),
        ],
    };
    let broadcast = LocalBroadcast::new();
    broadcast
        .video()
        .set(VideoInput::new(
            VideoFileSource {
                name: format!("file:{}", path.display()),
                format,
                rx,
            },
            codec::VideoCodec::H264,
            presets.iter().copied(),
        ))
        .map_err(|err| anyhow::anyhow!("video setup: {err:#}"))?;
    Ok((broadcast, import))
}

/// A running video-file publisher. Holds the live endpoint, router, and
/// broadcast; the tokio runtime is owned by this struct (see
/// [`crate::live::LivePublisher`] for why). Call [`VideoPublisher::stop`]
/// for graceful shutdown.
pub struct VideoPublisher {
    runtime: tokio::runtime::Runtime,
    live: Arc<Live>,
    // Dropping the broadcast tears down its producer/catalog and encode
    // pipelines, so it must be held for the publisher's lifetime.
    _broadcast: LocalBroadcast,
}

impl VideoPublisher {
    /// Simulcasts `path` as H.264 renditions over iroh-live. `presets`
    /// (default [180p, 360p, 720p]) are the quality ladder subscribers
    /// choose from; renditions above the source resolution are dropped.
    /// The broadcast ends when the file does (no loop support yet).
    pub fn start(
        path: &Path,
        name: &str,
        relay: bool,
        presets: Vec<VideoPreset>,
    ) -> anyhow::Result<(Self, String)> {
        let path = path.to_path_buf();
        let name = name.to_string();
        let handle = std::thread::spawn(move || Self::start_blocking(path, name, relay, presets));
        handle.join().map_err(|_| anyhow::anyhow!("publisher thread panicked"))?
    }

    fn start_blocking(
        path: PathBuf,
        name: String,
        relay: bool,
        presets: Vec<VideoPreset>,
    ) -> anyhow::Result<(Self, String)> {
        let runtime = tokio::runtime::Runtime::new()?;
        let (tx, rx) = std::sync::mpsc::sync_channel(FRAME_QUEUE);
        let result: anyhow::Result<(Arc<Live>, String, LocalBroadcast)> = runtime.block_on(async {
            let endpoint = build_endpoint(relay).await?;
            let live = Arc::new(Live::builder(endpoint).with_router().spawn());
            let (broadcast, import) = build_video_broadcast(&path, presets, rx).await?;
            // Feed the encode pipelines from the decode loop; when the file
            // ends the sender drops and the source reports "video ended".
            tokio::spawn(decode_loop(import.source, import.config, tx));
            live.publish(&name, &broadcast)
                .await
                .map_err(|err| anyhow::anyhow!("publish: {err:#}"))?;
            let ticket = LiveTicket::new(live.endpoint().addr(), &name).serialize();
            Ok((live, ticket, broadcast))
        });
        let (live, ticket, broadcast) = result?;
        Ok((
            Self {
                runtime,
                live,
                _broadcast: broadcast,
            },
            ticket,
        ))
    }

    /// Graceful shutdown: keeps the endpoint alive until the router drains.
    pub fn stop(self) {
        let _ = std::thread::spawn(move || {
            let live = self.live.clone();
            let _ = self
                .runtime
                .block_on(async move { live.shutdown().await });
            self.runtime.shutdown_timeout(Duration::from_secs(1));
        })
        .join();
    }
}

/// Dials `peer_addr` (a serde_json-serialized iroh `EndpointAddr`, as stored
/// in the daemon's peer registry) and publishes `path`'s video on the 1:1
/// session only — session-scoped, so no ticket exists. Blocks until the peer
/// hangs up (its subscribe session closes) or `seconds` elapses (`None` =
/// wait for hangup). Returns wall-clock time held open in milliseconds.
pub fn dial_to_peer(
    path: &Path,
    peer_addr: &str,
    seconds: Option<u64>,
    relay: bool,
) -> anyhow::Result<u64> {
    let path = path.to_path_buf();
    let peer_addr = peer_addr.to_string();
    // Multi-thread runtime: decode_loop's blocking channel sends must not
    // stall the executor driving the connect handshake.
    let handle = std::thread::spawn(move || {
        tokio::runtime::Runtime::new()?
            .block_on(dial_peer(&path, &peer_addr, seconds, relay))
    });
    handle.join().map_err(|_| anyhow::anyhow!("caller thread panicked"))?
}

async fn dial_peer(
    path: &Path,
    peer_addr: &str,
    seconds: Option<u64>,
    relay: bool,
) -> anyhow::Result<u64> {
    let addr: EndpointAddr = serde_json::from_str(peer_addr)
        .map_err(|err| anyhow::anyhow!("invalid peer endpoint address: {err}"))?;
    let endpoint = build_endpoint(relay).await?;
    // Outbound-only session: a bare Moq on a fresh endpoint, no inbound path.
    let moq = iroh_live::moq::Moq::new(endpoint);
    let (tx, rx) = mpsc::sync_channel(FRAME_QUEUE);
    let (broadcast, import) = build_video_broadcast(path, Vec::new(), rx).await?;
    tokio::spawn(decode_loop(import.source, import.config, tx));
    let session = moq
        .connect(addr)
        .await
        .map_err(|err| anyhow::anyhow!("connect to peer: {err:#}"))?;
    session.publish(crate::live::CALL_BROADCAST, broadcast.consume());
    let base = Instant::now();
    // The receiver controls the call length: it hangs up when its capture
    // window ends, which closes the session and releases us. `seconds` is a
    // safety cap for callers nobody hangs up on.
    match seconds {
        Some(cap) => tokio::time::sleep(Duration::from_secs(cap)).await,
        None => {
            let _ = session.conn().closed().await;
        }
    }
    let held_ms = base.elapsed().as_millis() as u64;
    Ok(held_ms)
}

/// Waits up to `wait` seconds for an inbound 1:1 video call on the daemon's
/// transport endpoint (the MoQ side-channel ALPN is registered for the
/// duration), accepts it, and records the caller's video rendition to an
/// Annex B `.h264` file, ending when the caller's broadcast ends or
/// `seconds` elapse. With `from` set, calls from any other endpoint are
/// rejected. `quality` selects the rendition to record (default highest).
pub fn answer_to_h264(
    transport: std::sync::Arc<idfon_core::transport::IrohTransport>,
    out: &Path,
    seconds: u64,
    wait: u64,
    from: Option<&str>,
    quality: Option<Quality>,
) -> anyhow::Result<VideoStats> {
    let out = out.to_path_buf();
    let from = from.map(str::to_string);
    // Multi-thread runtime for the same reason as dial_to_peer.
    let handle = std::thread::spawn(move || {
        tokio::runtime::Runtime::new()?.block_on(answer_h264(
            &transport,
            &out,
            seconds,
            wait,
            from.as_deref(),
            quality,
        ))
    });
    handle.join().map_err(|_| anyhow::anyhow!("answer thread panicked"))?
}

async fn answer_h264(
    transport: &idfon_core::transport::IrohTransport,
    out: &Path,
    seconds: u64,
    wait: u64,
    from: Option<&str>,
    quality: Option<Quality>,
) -> anyhow::Result<VideoStats> {
    use crate::live::CALL_BROADCAST;
    let from_id: Option<EndpointId> = match from {
        Some(id) => Some(id.parse().map_err(|err| anyhow::anyhow!("invalid --from endpoint id: {err}"))?),
        None => None,
    };
    // MoQ rides the daemon's transport endpoint via a side-channel ALPN: the
    // accept loop hands us raw connections, the handler turns them into
    // sessions, and the session stream is what `answer` waits on.
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
    let mut session = tokio::time::timeout(Duration::from_secs(wait), async {
        loop {
            let Some(call) = incoming.next().await else {
                anyhow::bail!("live transport shut down");
            };
            match from_id {
                Some(want) if call.remote_id() != want => call.reject(),
                _ => break Ok::<_, anyhow::Error>(call.accept()),
            }
        }
    })
    .await
    .map_err(|_| anyhow::anyhow!("no incoming call within {wait}s"))??;
    let mut last_err = String::new();
    const SUBSCRIBE_ATTEMPTS: u32 = 3;
    const SUBSCRIBE_TIMEOUT: Duration = Duration::from_secs(8);
    let remote = {
        let mut result = None;
        for _attempt in 0..SUBSCRIBE_ATTEMPTS {
            match tokio::time::timeout(SUBSCRIBE_TIMEOUT, session.subscribe(CALL_BROADCAST)).await {
                Ok(Ok(consumer)) => {
                    result = Some(
                        RemoteBroadcast::new(CALL_BROADCAST, consumer)
                            .await
                            .map_err(|err| anyhow::anyhow!("remote broadcast: {err:#}"))?,
                    );
                    break;
                }
                Ok(Err(err)) => last_err = format!("{err:#}"),
                Err(_) => last_err = "timed out waiting for the call broadcast to be announced".into(),
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        result.ok_or_else(|| anyhow::anyhow!("subscribe to caller failed after retries: {last_err}"))?
    };
    let stats = record_remote(&remote, out, seconds, 0, true, quality).await?;
    drop(remote);
    drop(session);
    drop(_side); // unregister the side channel
    Ok(stats)
}

/// Result of a [`listen_to_h264`] capture.
#[derive(Debug, Clone)]
pub struct VideoStats {
    /// Annex B H.264 file written.
    pub out: String,
    /// Encoded packets (frames) received.
    pub frames: u64,
    /// Encoded bytes written.
    pub bytes: u64,
    /// Wall-clock capture window in milliseconds.
    pub duration_ms: u64,
    /// Time from capture start to an established subscribe session.
    pub subscribe_ms: u64,
}

/// Holds Annex B SPS/PPS from the avcC description (avc1 shape) so keyframes
/// can be made self-contained; mirrors iroh-live's record path.
struct AnnexBState {
    sps_pps: Option<Vec<u8>>,
}

impl AnnexBState {
    fn from_config(config: &VideoConfig) -> Option<Self> {
        let config::VideoCodec::H264(ref h264) = config.codec else {
            return None;
        };
        let sps_pps = if !h264.inline {
            config
                .description
                .as_ref()
                .and_then(|desc| codec::h264::annexb::avcc_to_annex_b(desc))
        } else {
            None
        };
        Some(Self { sps_pps })
    }

    fn convert(&self, payload: &[u8], is_keyframe: bool) -> Vec<u8> {
        let mut out = codec::h264::annexb::length_prefixed_to_annex_b(payload);
        if is_keyframe {
            if let Some(ref sps_pps) = self.sps_pps {
                let mut with_sps = sps_pps.clone();
                with_sps.extend_from_slice(&out);
                out = with_sps;
            }
        }
        out
    }
}

/// Subscribes to a live ticket and records the selected rendition's encoded
/// video to an Annex B `.h264` file (playable with ffplay/mpv). Ends when
/// the broadcast ends or `seconds` elapse.
pub fn listen_to_h264(
    ticket: &str,
    out: &Path,
    seconds: u64,
    relay: bool,
    quality: Option<Quality>,
) -> anyhow::Result<VideoStats> {
    let ticket = ticket.to_string();
    let out = out.to_path_buf();
    let handle = std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(listen_h264(&ticket, &out, seconds, relay, quality))
    });
    handle.join().map_err(|_| anyhow::anyhow!("listener thread panicked"))?
}

async fn listen_h264(
    ticket: &str,
    out: &PathBuf,
    seconds: u64,
    relay: bool,
    quality: Option<Quality>,
) -> anyhow::Result<VideoStats> {
    let parsed: LiveTicket = ticket.parse()?;
    let remote_addr = parsed.endpoint.clone();
    let name = parsed.broadcast_name.clone();
    let local_endpoint = build_endpoint(relay).await?;
    let live = Live::builder(local_endpoint).spawn();
    let base = Instant::now();
    // Same bounded-retry subscribe as the audio path: a publisher whose
    // catalog announce hasn't landed yet would otherwise hang forever.
    const SUBSCRIBE_ATTEMPTS: u32 = 3;
    const SUBSCRIBE_TIMEOUT: Duration = Duration::from_secs(8);
    let mut last_err = String::new();
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
                Ok(Err(err)) => last_err = format!("{err:#}"),
                Err(_) => last_err = "timed out waiting for the broadcast to be announced".into(),
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        result.ok_or_else(|| anyhow::anyhow!("subscribe failed after retries: {last_err}"))?
    };
    let subscribe_ms = base.elapsed().as_millis() as u64;
    let broadcast = sub.broadcast();
    let stats = record_remote(broadcast, out, seconds, subscribe_ms, false, quality).await?;
    drop(sub);
    let _ = live.shutdown().await;
    Ok(stats)
}

/// Records `broadcast`'s selected video rendition to an Annex B `.h264`
/// file, ending when the broadcast ends, the caller hangs up (`hangup_ends`),
/// a few consecutive read timeouts pass, or `seconds` elapse. Shared by the
/// ticket path and the 1:1 answer path.
async fn record_remote(
    broadcast: &RemoteBroadcast,
    out: &Path,
    seconds: u64,
    subscribe_ms: u64,
    hangup_ends: bool,
    quality: Option<Quality>,
) -> anyhow::Result<VideoStats> {
    let base = Instant::now();
    let rendition = broadcast
        .catalog()
        .select_video_rendition(quality.unwrap_or(Quality::Highest))
        .map_err(|err| anyhow::anyhow!("no video rendition in broadcast: {err}"))?;
    let (source, hang_config) = broadcast.raw_video_track(&rendition)?;
    let config: VideoConfig = hang_config.into();
    // Only avc1-shaped streams (out-of-band SPS/PPS, length-prefixed NALs)
    // need conversion; inline (avc3) streams are already Annex B.
    let annex_b = match &config.codec {
        config::VideoCodec::H264(h264) if !h264.inline => AnnexBState::from_config(&config),
        _ => None,
    };

    let mut file = std::io::BufWriter::new(std::fs::File::create(out)?);
    use std::io::Write;
    let mut frames: u64 = 0;
    let mut bytes: u64 = 0;
    let mut source = source;
    let mut silence = Duration::ZERO;
    const READ_TIMEOUT: Duration = Duration::from_secs(2);
    while base.elapsed() < Duration::from_secs(seconds) {
        match tokio::time::timeout(READ_TIMEOUT, source.read()).await {
            Ok(Ok(Some(packet))) => {
                silence = Duration::ZERO;
                let payload = {
                    let mut payload = packet.payload;
                    let contiguous = payload.copy_to_bytes(payload.remaining());
                    contiguous.to_vec()
                };
                let written = match &annex_b {
                    Some(state) => state.convert(&payload, packet.is_keyframe),
                    None => payload,
                };
                bytes += written.len() as u64;
                frames += 1;
                file.write_all(&written)?;
            }
            Ok(Ok(None)) => break,
            Ok(Err(err)) => {
                if hangup_ends {
                    break; // the caller hanging up is a normal end
                }
                eprintln!("video track read error, stopping: {err:#}");
                break;
            }
            // No data in the window: give up after a few consecutive misses
            // so `seconds` actually bounds the capture.
            Err(_) => {
                silence += READ_TIMEOUT;
                if silence >= Duration::from_secs(6) {
                    break;
                }
            }
        }
    }
    file.flush()?;
    Ok(VideoStats {
        out: out.display().to_string(),
        frames,
        bytes,
        duration_ms: base.elapsed().as_millis() as u64,
        subscribe_ms,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh_live::media::format::VideoPreset;

    #[test]
    fn detects_video_formats() {
        assert!(matches!(
            detect_format(Path::new("a/b.MP4")).unwrap(),
            FramedFormat::Fmp4
        ));
        assert!(matches!(
            detect_format(Path::new("x.webm")).unwrap(),
            FramedFormat::Mkv
        ));
        assert!(detect_format(Path::new("x.txt")).is_err());
    }

    #[test]
    fn annex_b_wraps_keyframes_with_parameter_sets() {
        // Minimal valid avcC record: header(5) + num_sps + sps(2) + num_pps + pps(2).
        let description: Vec<u8> = vec![
            0x01, 0x42, 0x00, 0x1e, 0xff, 0xe1, 0, 2, 0x67, 0x42, 1, 0, 2, 0x68, 0xce,
        ];
        let config = VideoConfig {
            codec: config::VideoCodec::H264(config::H264 {
                inline: false,
                profile: 0x42,
                constraints: 0,
                level: 0x1e,
            }),
            description: Some(bytes::Bytes::from(description)),
            coded_width: Some(320),
            coded_height: Some(240),
            display_ratio_width: None,
            display_ratio_height: None,
            bitrate: None,
            framerate: Some(30.0),
            optimize_for_latency: None,
        };
        let state = AnnexBState::from_config(&config).expect("h264 config");
        // Keyframe: length-prefixed NAL -> start codes, SPS/PPS prepended.
        let keyframe = [0, 0, 0, 2, 0x65, 0x88];
        let converted = state.convert(&keyframe, true);
        assert!(converted.starts_with(&[0, 0, 0, 1, 0x67, 0x42]));
        assert!(converted.windows(4).any(|w| w == [0, 0, 1, 0x65]));
        // Non-keyframe: conversion only, no SPS/PPS.
        let delta = [0, 0, 0, 2, 0x41, 0x9a];
        let converted = state.convert(&delta, false);
        assert_eq!(converted, vec![0, 0, 0, 1, 0x41, 0x9a]);
    }

    #[test]
    fn preset_filter_keeps_smallest_when_source_is_tiny() {
        let mut presets: Vec<VideoPreset> =
            [VideoPreset::P180, VideoPreset::P360, VideoPreset::P720].to_vec();
        let height = 120u32;
        presets.retain(|preset| preset.height() <= height);
        if presets.is_empty() {
            presets = [VideoPreset::P180].to_vec();
        }
        assert_eq!(presets, vec![VideoPreset::P180]);
    }
}



#[cfg(test)]
mod video_smoke {
    use super::*;

    /// End-to-end smoke for the import path; requires a fragmented MP4 at
    /// /tmp/vid.mp4 (generated with ffmpeg, see docs) and skips otherwise.
    #[tokio::test]
    async fn import_file_async_smoke() -> anyhow::Result<()> {
        if !Path::new("/tmp/vid.mp4").is_file() {
            return Ok(());
        }
        let import = import_file(Path::new("/tmp/vid.mp4")).await?;
        assert!(import.config.coded_width.unwrap_or(0) > 0);
        Ok(())
    }
}

#[cfg(test)]
mod decode_debug {
    use super::*;

    /// Drives decode_loop directly and counts produced frames; requires a
    /// fragmented baseline-profile MP4 at /tmp/vid.mp4 and skips otherwise.
    /// openh264 only decodes H.264 baseline (no B-frames) — source files for
    /// streaming must be encoded accordingly.
    #[tokio::test]
    async fn decode_loop_produces_frames() -> anyhow::Result<()> {
        if !Path::new("/tmp/vid.mp4").is_file() {
            return Ok(());
        }
        let import = import_file(Path::new("/tmp/vid.mp4")).await?;
        let (tx, rx) = mpsc::sync_channel::<VideoFrame>(64);
        tokio::spawn(decode_loop(import.source, import.config, tx));

        // Count on a plain thread; poll the count from the async side.
        let (count_tx, count_rx) = std::sync::mpsc::channel::<usize>();
        std::thread::spawn(move || {
            let mut count = 0usize;
            let start = std::time::Instant::now();
            loop {
                match rx.recv_timeout(Duration::from_millis(500)) {
                    Ok(_frame) => count += 1,
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        let _ = count_tx.send(count);
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        let _ = count_tx.send(count);
                        return;
                    }
                }
                if start.elapsed() > Duration::from_secs(10) {
                    let _ = count_tx.send(count);
                    return;
                }
            }
        });

        let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
        let mut frames = 0;
        while tokio::time::Instant::now() < deadline {
            // Yield to the runtime so the spawned decode task is polled.
            tokio::time::sleep(Duration::from_millis(500)).await;
            match count_rx.try_recv() {
                Ok(count) => {
                    frames = count;
                    if frames > 0 {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        println!("decoded frames: {frames}");
        assert!(frames > 0, "decode_loop produced no frames");
        Ok(())
    }
}
