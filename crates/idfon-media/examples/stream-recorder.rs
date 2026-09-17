//! Record decoded audio from a current iroh-live broadcast.

use std::time::Duration;

use iroh_live::Live;
use moq_audio::{decode::{Config, Consumer}, Format};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let ticket: iroh_live::ticket::LiveTicket = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("usage: stream-recorder <TICKET> [SECONDS]"))?
        .parse()?;
    let seconds = args.next().map(|s| s.parse()).transpose()?.unwrap_or(15);
    let live = Live::from_env().await?.spawn();
    let subscription = live.subscribe(ticket.endpoint, &ticket.broadcast_name).await?;
    let broadcast = subscription.broadcast();
    let catalog = broadcast.catalog();
    let name = catalog.first_audio().ok_or_else(|| anyhow::anyhow!("no audio track"))?;
    let config = catalog.audio().get(name).ok_or_else(|| anyhow::anyhow!("audio catalog missing"))?;
    let mut decode_config = Config::new();
    decode_config.format = Format::F32;
    decode_config.sample_rate = Some(48_000);
    decode_config.channels = Some(1);
    let mut decoder = Consumer::new(
        broadcast.consumer(), config, name, decode_config,
    ).await?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(seconds);
    let mut samples = Vec::new();
    while tokio::time::Instant::now() < deadline {
        let Some(frame) = decoder.read().await? else { break };
        for chunk in frame.data.chunks_exact(4) {
            samples.push(f32::from_le_bytes(chunk.try_into().unwrap()));
        }
    }
    let mut wav = Vec::with_capacity(44 + samples.len() * 2);
    let data_len = (samples.len() * 2) as u32;
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&48_000u32.to_le_bytes());
    wav.extend_from_slice(&96_000u32.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    for sample in samples {
        wav.extend_from_slice(&((sample.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
    }
    std::fs::write("stream-recording.wav", wav)?;
    live.shutdown().await;
    Ok(())
}
