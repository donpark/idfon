//! Cascade backend: caller audio → STT → agent turn → TTS → return audio.
//!
//! The engine is built from the voice agent's `engine` config via
//! [`idfon_voice::providers::build_engine`] (any OpenAI-compatible provider, or
//! a split such as Deepgram STT + ElevenLabs TTS). It sits behind the
//! [`VoiceBackend`] seam, so swapping providers changes nothing above.
//!
//! TTS streams two ways: agent-output deltas arrive on `media.deltas` and are
//! fed to `StreamingSpeaker` (envelope strip, clause batching, retry dedupe);
//! and providers that support it push synthesized audio straight to an
//! [`AudioSink`] as they produce it (`tts_with_sink`). Batch providers return
//! chunks, which are routed through the same sink.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use idfon_voice::{
    normalize_for_speech, AudioFormat, AudioSink, EndpointEvent, MessageDelta, PcmChunk,
    StreamingSpeaker, VoiceEngine,
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

        let mut pending: Option<(u64, u64)> = None; // (stt_ms, caller_audio_ms)
        let mut caller_frames = 0u64;

        // Every synthesized chunk goes through one sink: batch adapters return
        // chunks we forward, streaming adapters call the sink as audio arrives.
        let first_ms = Arc::new(AtomicU64::new(0));
        let audio_ms = Arc::new(AtomicU64::new(0));
        let reply_started = Arc::new(Mutex::new(Instant::now()));
        let sink: AudioSink = {
            let queue = media.audio.clone();
            let first = Arc::clone(&first_ms);
            let audio = Arc::clone(&audio_ms);
            let started = Arc::clone(&reply_started);
            Arc::new(move |chunk: PcmChunk| {
                let elapsed = started
                    .lock()
                    .map(|started| started.elapsed().as_millis() as u64)
                    .unwrap_or(0);
                let _ = first.compare_exchange(0, elapsed.max(1), Ordering::Relaxed, Ordering::Relaxed);
                audio.fetch_add(samples_ms(&chunk, format), Ordering::Relaxed);
                queue.push_samples(&chunk.samples);
            })
        };
        let mut speaker: Option<StreamingSpeaker> = None;
        let mut deltas_seen = false;

        loop {
            tokio::select! {
                item = media.caller.recv() => {
                    let Some(pcm) = item else { break };
                    caller_frames += 1;
                    let _ = stt.push(&pcm);
                    if let Some(EndpointEvent::SpeechEnded) = endpointer.push(&pcm)? {
                        // Close out any in-flight reply before the next turn.
                        if let Some(mut active) = speaker.take() {
                            emit(active.finish()?, &sink);
                        }
                        deltas_seen = false;
                        first_ms.store(0, Ordering::Relaxed);
                        audio_ms.store(0, Ordering::Relaxed);
                        if let Ok(mut started) = reply_started.lock() { *started = Instant::now(); }
                        let started = Instant::now();
                        if let Some(text) = stt.flush()? {
                            let text = text.trim().to_string();
                            if !text.is_empty() {
                                pending = Some((
                                    started.elapsed().as_millis() as u64,
                                    caller_frames * idfon_live_media::CHUNK_MS,
                                ));
                                media.bridge.record("caller", &text);
                                media.bridge.inject(&text).await;
                            }
                        }
                        caller_frames = 0;
                    }
                }
                Some((turn_id, step, seq, text)) = media.deltas.recv() => {
                    if speaker.is_none() {
                        speaker = Some(StreamingSpeaker::new(
                            self.engine.tts_with_sink("default", format, sink.clone())?,
                        ));
                        if let Ok(mut started) = reply_started.lock() { *started = Instant::now(); }
                    }
                    deltas_seen = true;
                    let chunks = speaker
                        .as_mut()
                        .expect("speaker just set")
                        .push(MessageDelta::new(turn_id, step, seq, &text))?;
                    emit(chunks, &sink);
                }
                Some((_turn_id, reply)) = media.bridge.next_reply() => {
                    let spoken = strip_envelopes(&reply);
                    if deltas_seen {
                        if let Some(mut active) = speaker.take() {
                            emit(active.finish()?, &sink);
                        }
                    } else if !spoken.is_empty() {
                        // Fallback: no deltas (older bridge) — speak the whole reply.
                        if let Ok(mut started) = reply_started.lock() { *started = Instant::now(); }
                        let mut whole = StreamingSpeaker::new(
                            self.engine.tts_with_sink("default", format, sink.clone())?,
                        );
                        let normalized = normalize_for_speech(&spoken);
                        let chunks = whole.push(MessageDelta::new("reply", 0, 0, &normalized))?;
                        emit(chunks, &sink);
                        let tail = whole.finish()?;
                        emit(tail, &sink);
                    }
                    let (stt_ms, caller_audio_ms) = pending.take().unwrap_or((0, 0));
                    let mut metrics = TurnMetrics {
                        provider: self.provider.clone(),
                        stt_ms,
                        tts_first_ms: first_ms.load(Ordering::Relaxed).max(1),
                        tts_total_ms: reply_started
                            .lock()
                            .map(|started| started.elapsed().as_millis() as u64)
                            .unwrap_or(0),
                        caller_audio_ms,
                        tts_audio_ms: audio_ms.load(Ordering::Relaxed),
                        tts_chars: spoken.chars().count(),
                        est_cost_usd: None,
                    };
                    metrics.est_cost_usd = metrics.cost_estimate();
                    metrics.log();
                    media.bridge.record("agent", &spoken);
                    speaker = None;
                    deltas_seen = false;
                    first_ms.store(0, Ordering::Relaxed);
                    audio_ms.store(0, Ordering::Relaxed);
                }
                _ = tick.tick() => {
                    if media.stop.load(Ordering::Relaxed) { break; }
                }
            }
        }
        Ok(())
    }
}

fn emit(chunks: Vec<PcmChunk>, sink: &AudioSink) {
    for chunk in chunks {
        sink(chunk);
    }
}

fn samples_ms(chunk: &PcmChunk, format: AudioFormat) -> u64 {
    (chunk.samples.len() as u64 * 1000) / (format.sample_rate as u64 * format.channels.max(1) as u64)
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
