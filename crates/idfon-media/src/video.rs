//! Current MoQ video integration.
//!
//! Video is built from the current `moq-media` source model. Pre-encoded Annex-B
//! H.264 uses `VideoSource::AnnexB`; MP4/MKV/TS/FLV inputs use the current
//! `moq_mux::import::Container` path.

use std::path::Path;

use bytes::Bytes;
use iroh::protocol::ProtocolHandler as _;
use iroh_live::{ticket::LiveTicket, Call, Live};
use moq_media::{publish::{VideoRendition, VideoSource}, video::Size};
use moq_video::encode::{Config as EncodeConfig, Encoder};
use n0_future::boxed::BoxStream;

use crate::live::build_endpoint;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Quality { Low, Mid, High, Highest }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoPreset { P180, P360, P720, P1080 }

impl std::str::FromStr for VideoPreset {
    type Err = ();
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.to_ascii_lowercase().as_str() {
            "180p" | "p180" => Ok(Self::P180),
            "360p" | "p360" => Ok(Self::P360),
            "720p" | "p720" => Ok(Self::P720),
            "1080p" | "p1080" => Ok(Self::P1080),
            _ => Err(()),
        }
    }
}

pub struct VideoPublisher {
    runtime: tokio::runtime::Runtime,
    live: Live,
    broadcast: Option<moq_media::publish::LocalBroadcast>,
    catalog: Option<moq_mux::catalog::Producer>,
    import_task: Option<tokio::task::JoinHandle<()>>,
}

impl VideoPublisher {
    pub fn start(
        path: &Path,
        name: &str,
        relay: bool,
        presets: Vec<VideoPreset>,
    ) -> anyhow::Result<(Self, String)> {
        let path = path.to_path_buf();
        let name = name.to_owned();
        let presets = if presets.is_empty() { vec![VideoPreset::P720] } else { presets };
        let runtime = tokio::runtime::Runtime::new()?;
        let (live, broadcast, catalog, import_task, ticket) = runtime.block_on(async move {
            let endpoint = build_endpoint(relay).await?;
            let live = Live::builder(endpoint).with_router().spawn();
            let extension = path.extension().and_then(|value| value.to_str()).unwrap_or_default().to_ascii_lowercase();
            if matches!(extension.as_str(), "mp4" | "m4v" | "mov" | "cmfv" | "mkv" | "webm" | "ts" | "m2ts" | "flv") {
                let mut raw = live.publish_raw(&name)?;
                let catalog = moq_mux::catalog::Producer::new(&mut raw)?;
                let reserve = catalog.reserve();
                let data = std::fs::read(&path)?;
                let first_chunk_len = data.len().min(256 * 1024);
                let mut container = moq_mux::import::Container::new(raw, reserve, match extension.as_str() {
                    "mkv" | "webm" => "mkv",
                    "ts" | "m2ts" => "ts",
                    "flv" => "flv",
                    _ => "fmp4",
                }, &data[..first_chunk_len])?;
                let ticket = LiveTicket::new(live.endpoint().id(), &name).serialize();
                let import_task = tokio::spawn(async move {
                    for chunk in data[first_chunk_len..].chunks(256 * 1024) {
                        if container.decode(chunk).is_err() { return; }
                        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                    }
                    let _ = container.finish();
                });
                Ok::<_, anyhow::Error>((live, None, Some(catalog), Some(import_task), ticket))
            } else {
                let broadcast = live.publish(&name)?;
                let source = annexb_source(&path)?;
                broadcast.video().set_renditions(
                    source,
                    presets.iter().map(|preset| {
                        let (name, size) = match preset {
                            VideoPreset::P180 => ("180p", Size { width: 320, height: 180 }),
                            VideoPreset::P360 => ("360p", Size { width: 640, height: 360 }),
                            VideoPreset::P720 => ("720p", Size { width: 1280, height: 720 }),
                            VideoPreset::P1080 => ("1080p", Size { width: 1920, height: 1080 }),
                        };
                        VideoRendition::new(name).with_size(size)
                    }).collect(),
                )?;
                let ticket = LiveTicket::new(live.endpoint().id(), &name).serialize();
                Ok::<_, anyhow::Error>((live, Some(broadcast), None, None, ticket))
            }
        })?;
        Ok((Self { runtime, live, broadcast, catalog, import_task }, ticket))
    }

    pub fn stop(self) {
        if let Some(task) = self.import_task { task.abort(); }
        drop(self.broadcast);
        drop(self.catalog);
        let _ = self.runtime.block_on(self.live.shutdown());
    }
}

fn annexb_source(path: &Path) -> anyhow::Result<VideoSource> {
    let data = std::fs::read(path)
        .map_err(|err| anyhow::anyhow!("cannot read {}: {err}", path.display()))?;
    if !data.windows(4).any(|w| w == [0, 0, 0, 1]) {
        anyhow::bail!("video source must be Annex-B H.264 or a supported container")
    }
    let stream: BoxStream<Bytes> = Box::pin(n0_future::stream::iter([Bytes::from(data)]));
    Ok(VideoSource::AnnexB(stream))
}

pub fn listen_to_h264(
    ticket: &str,
    out: &Path,
    seconds: u64,
    _relay: bool,
    quality: Option<Quality>,
) -> anyhow::Result<VideoStats> {
    let ticket = ticket.parse::<LiveTicket>()?;
    let out = out.to_path_buf();
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Runtime::new()?;
        runtime.block_on(async move {
            let live = Live::from_env().await?.spawn();
            let subscription = live.subscribe(ticket.endpoint, &ticket.broadcast_name).await?;
            let track = if let Some(quality) = quality {
                let catalog = subscription.broadcast().catalog();
                let wanted = match quality {
                    Quality::Low => "180p",
                    Quality::Mid => "360p",
                    Quality::High => "720p",
                    Quality::Highest => "1080p",
                };
                if catalog.video().contains_key(wanted) {
                    subscription.broadcast().video_rendition(wanted).await?
                } else {
                    subscription.broadcast().video().await?
                }
            } else {
                subscription.broadcast().video().await?
            };
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(seconds);
            let mut encoder: Option<Encoder> = None;
            let mut encoded = Vec::new();
            let mut frames = 0usize;
            while tokio::time::Instant::now() < deadline {
                let Some(frame) = track.recv().await else { break; };
                if encoder.is_none() {
                    let size = frame.size();
                    encoder = Some(Encoder::new(&EncodeConfig::new(size.width, size.height, 30))?);
                }
                if let Some(encoder) = encoder.as_mut() {
                    for unit in encoder.encode(&frame)? { encoded.extend_from_slice(&unit.payload); }
                }
                frames += 1;
            }
            std::fs::write(&out, &encoded)?;
            live.shutdown().await;
            Ok(VideoStats { duration_ms: seconds * 1000, packets: frames, subscribe_ms: 0, out: out.display().to_string(), frames, bytes: encoded.len() as u64 })
        })
    }).join().map_err(|_| anyhow::anyhow!("video listener thread panicked"))?
}

pub fn dial_to_peer(
    path: &Path,
    peer_addr: &str,
    seconds: Option<u64>,
    relay: bool,
) -> anyhow::Result<u64> {
    let path = path.to_path_buf();
    let peer_addr = peer_addr.to_owned();
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Runtime::new()?;
        runtime.block_on(async move {
            let endpoint = build_endpoint(relay).await?;
            let live = Live::builder(endpoint).with_router().spawn();
            let call_path = Call::path(live.endpoint().id());
            let broadcast = live.publish(&call_path)?;
            broadcast.video().set_renditions(
                annexb_source(&path)?,
                vec![VideoRendition::new("video")],
            )?;
            let addr: iroh::EndpointAddr = serde_json::from_str(&peer_addr)?;
            let call = Call::dial(&live, addr).await.map_err(|err| anyhow::anyhow!("dial: {err}"))?;
            let started = std::time::Instant::now();
            match seconds {
                Some(seconds) => tokio::time::sleep(std::time::Duration::from_secs(seconds)).await,
                None => { call.closed().await; }
            }
            let elapsed = started.elapsed().as_millis() as u64;
            call.close();
            live.shutdown().await;
            Ok(elapsed)
        })
    }).join().map_err(|_| anyhow::anyhow!("video dial thread panicked"))?
}

pub fn answer_to_h264(
    transport: std::sync::Arc<idfon_core::transport::IrohTransport>,
    out: &Path,
    seconds: u64,
    wait: u64,
    from: Option<&str>,
    _quality: Option<Quality>,
) -> anyhow::Result<VideoStats> {
    let out = out.to_path_buf();
    let from = from.map(str::to_owned);
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Runtime::new()?;
        runtime.block_on(async move {
            let moq = iroh_live::moq::Moq::new(transport.endpoint().clone());
            let handler = moq.protocol_handler();
            let (tx, mut rx) = tokio::sync::mpsc::channel(8);
            let _side = transport.add_side_channel(iroh_live::moq::ALPN, tx);
            tokio::spawn(async move {
                while let Some(connection) = rx.recv().await {
                    let handler = handler.clone();
                    tokio::spawn(async move { let _ = handler.accept(connection).await; });
                }
            });
            let wanted = from.as_deref().map(str::parse).transpose()?;
            let mut incoming = moq.incoming_sessions();
            let session = tokio::time::timeout(std::time::Duration::from_secs(wait), async {
                loop {
                    let Some(session) = incoming.next().await else { anyhow::bail!("live transport shut down"); };
                    if wanted.is_none_or(|id| session.remote_id() == id) { break Ok::<_, anyhow::Error>(session); }
                }
            }).await.map_err(|_| anyhow::anyhow!("no incoming call within {wait}s"))??;
            let call = Call::accept(session).await.map_err(|err| anyhow::anyhow!("accept: {err}"))?;
            let track = call.remote().video().await.map_err(|err| anyhow::anyhow!("video: {err}"))?;
            let result = record_video_track(track, &out, seconds).await;
            call.close();
            result
        })
    }).join().map_err(|_| anyhow::anyhow!("video answer thread panicked"))?
}

async fn record_video_track(
    track: moq_media::subscribe::VideoTrack,
    out: &Path,
    seconds: u64,
) -> anyhow::Result<VideoStats> {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(seconds);
    let mut encoder = None;
    let mut bytes = Vec::new();
    let mut frames = 0;
    while tokio::time::Instant::now() < deadline {
        let Some(frame) = track.recv().await else { break; };
        if encoder.is_none() {
            let size = frame.size();
            encoder = Some(Encoder::new(&EncodeConfig::new(size.width, size.height, 30))?);
        }
        for unit in encoder.as_mut().unwrap().encode(&frame)? { bytes.extend_from_slice(&unit.payload); }
        frames += 1;
    }
    std::fs::write(out, &bytes)?;
    Ok(VideoStats { duration_ms: seconds * 1000, packets: frames, subscribe_ms: 0, out: out.display().to_string(), frames, bytes: bytes.len() as u64 })
}

#[derive(Debug, Clone, Default)]
pub struct VideoStats {
    pub duration_ms: u64,
    pub packets: usize,
    pub subscribe_ms: u64,
    pub out: String,
    pub frames: usize,
    pub bytes: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_presets() {
        assert_eq!("180p".parse(), Ok(VideoPreset::P180));
        assert!("1080p".parse::<VideoPreset>().is_err());
    }
}
