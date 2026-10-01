//! Offline gate for the voice provider seam: text → PCM → WAV with the stub
//! engine. Run by `scripts/voice-pipeline-check.sh`; no network, no credentials.

use std::path::PathBuf;

use anyhow::Result;
use idfon_voice::{synthesize_to_wav, AudioFormat, StubVoiceEngine, VoiceEngine};

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let path = args
        .next()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("voice-pipeline.wav"));
    let text = args
        .next()
        .unwrap_or_else(|| "Offline voice pipeline check.".to_string());

    let engine = StubVoiceEngine::new();
    let samples = synthesize_to_wav(&engine, &text, "default", AudioFormat::PCM_24K_MONO, &path)?;
    println!(
        "engine={} samples={} path={}",
        engine.name(),
        samples,
        path.display()
    );
    Ok(())
}
