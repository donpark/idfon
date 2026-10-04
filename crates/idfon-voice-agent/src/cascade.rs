//! Cascade backend: caller audio → STT → agent turn → TTS → return audio.
//!
//! The engine is built from the voice agent's `engine` config via
//! [`idfon_voice::providers::build_engine`] (any OpenAI-compatible provider, or
//! a split such as Deepgram STT + ElevenLabs TTS). It sits behind the
//! [`VoiceBackend`] seam, so swapping providers changes nothing above.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use idfon_voice::{
    normalize_for_speech, AudioFormat, EndpointEvent, VoiceEngine,
};
use serde_json::Value;
use tokio::time::MissedTickBehavior;

use crate::metrics::TurnMetrics;
use crate::{strip_envelopes, BackendFuture, VoiceBackend, VoiceBackendFactory, VoiceMedia};

/// Cascade: STT the caller, run a normal agent turn, TTS the reply.
pub struct CascadeBackend {
    engine: Arc<dyn VoiceEngine>,
    provider: String,
    format: AudioFormat,
}

impl VoiceBackend for CascadeBackend {
    fn name(&self) -> &str {
        "cascade"
    }

    fn run(&mut self, media: VoiceMedia) -> BackendFuture<'_> {
        Box::pin(self.run_loop(media))
    }
}

impl CascadeBackend {
    async fn run_loop(&mut self, mut media: VoiceMedia) -> Result<()> {
        let format = self.format;
        let mut stt = self.engine.stt(format)?;
        let mut endpointer = self.engine.endpointer(format)?;
        let mut tick = tokio::time::interval(Duration::from_millis(200));
        tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
        // Timing carried from the caller utterance to its reply.
        let mut pending: Option<(u64, u64)> = None; // (stt_ms, caller_audio_ms)
        let mut caller_frames = 0u64;

        loop {
            tokio::select! {
                item = media.caller.recv() => {
                    let Some(pcm) = item else { break };
                    caller_frames += 1;
                    let _ = stt.push(&pcm);
                    if let Some(EndpointEvent::SpeechEnded) = endpointer.push(&pcm)? {
                        let started = Instant::now();
                        if let Some(text) = stt.flush()? {
                            let text = text.trim().to_string();
                            if !text.is_empty() {
                                let stt_ms = started.elapsed().as_millis() as u64;
                                let caller_audio_ms = caller_frames * idfon_live_media::CHUNK_MS;
                                pending = Some((stt_ms, caller_audio_ms));
                                media.bridge.record("caller", &text);
                                media.bridge.inject(&text).await;
                            }
                        }
                        caller_frames = 0;
                    }
                }
                Some((_turn_id, reply)) = media.bridge.next_reply() => {
                    let spoken = strip_envelopes(&reply);
                    if spoken.is_empty() { continue; }
                    let normalized = normalize_for_speech(&spoken);
                    let started = Instant::now();
                    let mut first_ms = 0u64;
                    let mut audio_ms = 0u64;
                    let mut chars = 0usize;
                    let mut tts = self.engine.tts("default", format)?;
                    let emit = |chunks: Vec<idfon_voice::PcmChunk>, first_ms: &mut u64, audio_ms: &mut u64| {
                        for chunk in chunks {
                            if *first_ms == 0 {
                                *first_ms = started.elapsed().as_millis() as u64;
                            }
                            *audio_ms += (chunk.samples.len() as u64 * 1000)
                                / (format.sample_rate as u64 * format.channels.max(1) as u64);
                            media.audio.push_samples(&chunk.samples);
                        }
                    };
                    chars += normalized.chars().count();
                    emit(tts.push_text(&normalized).unwrap_or_default(), &mut first_ms, &mut audio_ms);
                    emit(tts.finish().unwrap_or_default(), &mut first_ms, &mut audio_ms);
                    let tts_total_ms = started.elapsed().as_millis() as u64;
                    let (stt_ms, caller_audio_ms) = pending.take().unwrap_or((0, 0));
                    let mut metrics = TurnMetrics {
                        provider: self.provider.clone(),
                        stt_ms,
                        tts_first_ms: first_ms,
                        tts_total_ms,
                        caller_audio_ms,
                        tts_audio_ms: audio_ms,
                        tts_chars: chars,
                        est_cost_usd: None,
                    };
                    metrics.est_cost_usd = metrics.cost_estimate();
                    metrics.log();
                    media.bridge.record("agent", &spoken);
                }
                _ = tick.tick() => {
                    if media.stop.load(std::sync::atomic::Ordering::Relaxed) { break; }
                }
            }
        }
        Ok(())
    }
}

/// Builds a [`CascadeBackend`] from the live config.
pub struct CascadeFactory;

impl VoiceBackendFactory for CascadeFactory {
    fn kind(&self) -> &str {
        "cascade"
    }

    fn create(&self, params: &Value) -> Result<Box<dyn VoiceBackend>> {
        Ok(Box::new(CascadeBackend {
            // The voice agent's `engine` block selects the provider(s); no
            // block = AI Gateway env.
            engine: idfon_voice::providers::build_engine(params.get("engine"))?,
            provider: provider_label(params.get("engine")),
            format: AudioFormat::PCM_24K_MONO,
        }))
    }
}

/// Best-effort provider name(s) for metrics/cost: `stt|tts` for a split engine.
fn provider_label(engine: Option<&Value>) -> String {
    let Some(engine) = engine.filter(|value| !value.is_null()) else {
        return "gateway".to_string();
    };
    let name = |value: &Value| {
        value
            .get("provider")
            .and_then(|provider| provider.as_str())
            .unwrap_or("openai-compatible")
            .to_string()
    };
    if let Some(stt) = engine.get("stt") {
        let tts = engine
            .get("tts")
            .map(&name)
            .unwrap_or_else(|| "openai-compatible".to_string());
        return format!("{}|{}", name(stt), tts);
    }
    name(engine)
}
