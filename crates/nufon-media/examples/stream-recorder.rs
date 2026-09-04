//! Headless live-audio receiver: subscribe to a live ticket, decode Opus,
//! write a WAV plus per-packet arrival timings (for latency/jitter analysis).
//!
//! Usage: cargo run -p nufon-media --example stream-recorder -- <TICKET> --seconds 15 --out /tmp/rec

use std::time::{Duration, Instant};

use bytes::Buf;

use iroh_live::media::{
    codec::OpusAudioDecoder,
    config::{AudioCodec, AudioConfig},
    format::AudioFormat,
    traits::AudioDecoder,
    transport::PacketSource,
};
use iroh_live::Live;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let ticket: iroh_live::ticket::LiveTicket = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("usage: stream-recorder <TICKET> [--seconds N] [--out PREFIX]"))?
        .parse()?;
    let mut seconds = 15u64;
    let mut out = std::path::PathBuf::from("stream-recording");
    let mut a = args;
    while let Some(arg) = a.next() {
        match arg.as_str() {
            "--seconds" => seconds = a.next().ok_or_else(|| anyhow::anyhow!("--seconds needs a value"))?.parse()?,
            "--out" => out = a.next().ok_or_else(|| anyhow::anyhow!("--out needs a value"))?.into(),
            other => anyhow::bail!("unknown arg {other}"),
        }
    }

    let live = Live::from_env().await?.spawn();
    let sub = live.subscribe(ticket.endpoint, &ticket.broadcast_name).await?;
    let broadcast = sub.broadcast();
    let audio = broadcast
        .catalog()
        .select_audio_rendition(iroh_live::media::format::Quality::Highest)?;

    let (mut source, config) = broadcast.raw_audio_track(&audio)?;
    println!(
        "audio track {audio}: {} Hz, {} ch",
        config.sample_rate, config.channel_count
    );

    let mut decoder = OpusAudioDecoder::new(
        &AudioConfig {
            codec: AudioCodec::Opus,
            sample_rate: config.sample_rate,
            channel_count: config.channel_count,
            bitrate: None,
            description: None,
        },
        AudioFormat::mono_48k(),
    )?;

    let start = Instant::now();
    let wall_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis();
    let mut samples: Vec<f32> = Vec::new();
    let mut timings: Vec<(u128, u128, usize)> = Vec::new(); // (arrival_ms, pts_ms, bytes)

    while start.elapsed() < Duration::from_secs(seconds) {
        let Some(pkt) = source.read().await? else { break };
        let bytes = pkt.payload.remaining();
        let pts_ms = pkt.timestamp.as_millis();
        match decoder.push_packet(pkt) {
            Ok(()) => {}
            Err(e) => {
                eprintln!("decode error: {e}");
                continue;
            }
        }
        while let Some(buf) = decoder.pop_samples()? {
            samples.extend_from_slice(buf);
        }
        timings.push((start.elapsed().as_millis(), pts_ms, bytes));
    }
    drop(sub);
    live.shutdown().await;

    // WAV (16-bit PCM mono 48k)
    let wav = out.with_extension("wav");
    let mut w = Vec::with_capacity(44 + samples.len() * 2);
    w.extend_from_slice(b"RIFF");
    let data_len = (samples.len() * 2) as u32;
    w.extend_from_slice(&(36 + data_len).to_le_bytes());
    w.extend_from_slice(b"WAVEfmt ");
    w.extend_from_slice(&16u32.to_le_bytes());
    w.extend_from_slice(&1u16.to_le_bytes()); // PCM
    w.extend_from_slice(&1u16.to_le_bytes()); // mono
    w.extend_from_slice(&48000u32.to_le_bytes());
    w.extend_from_slice(&96000u32.to_le_bytes()); // byte rate
    w.extend_from_slice(&2u16.to_le_bytes()); // block align
    w.extend_from_slice(&16u16.to_le_bytes()); // bits
    w.extend_from_slice(b"data");
    w.extend_from_slice(&data_len.to_le_bytes());
    for s in &samples {
        let v = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
        w.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(&wav, &w)?;

    // timings JSON
    let json = format!(
        "{{\"wall_ms\": {wall_ms}, \"packets\": [{}]}}",
        timings
            .iter()
            .map(|(t, p, b)| format!("{{\"t_ms\":{t},\"pts_ms\":{p},\"bytes\":{b}}}"))
            .collect::<Vec<_>>()
            .join(",")
    );
    std::fs::write(out.with_extension("timings.json"), json)?;

    println!(
        "wrote {} ({} ms of audio) and {} ({} packets)",
        wav.display(),
        samples.len() / 48,
        out.with_extension("timings.json").display(),
        timings.len(),
    );
    Ok(())
}
