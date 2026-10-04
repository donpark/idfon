//! Cascade backend: caller audio → STT → agent turn → TTS → return audio.
//!
//! The engine is [`idfon_voice::gateway::GatewayVoiceEngine`] (cloud). It sits
//! behind the same [`VoiceBackend`] seam as any full-duplex or local engine, so
//! swapping it changes nothing above.

use std::time::Duration;

use anyhow::Result;
use idfon_voice::{
    gateway::OpenAiCompatEngine, normalize_for_speech, AudioFormat, EndpointEvent, VoiceEngine,
};
use serde_json::Value;
use tokio::time::MissedTickBehavior;

use crate::{strip_envelopes, BackendFuture, VoiceBackend, VoiceBackendFactory, VoiceMedia};

/// Cascade: STT the caller, run a normal agent turn, TTS the reply.
pub struct CascadeBackend {
    engine: OpenAiCompatEngine,
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
        loop {
            tokio::select! {
                item = media.caller.recv() => {
                    let Some(pcm) = item else { break };
                    let _ = stt.push(&pcm);
                    if let Some(EndpointEvent::SpeechEnded) = endpointer.push(&pcm)? {
                        if let Some(text) = stt.flush()? {
                            let text = text.trim().to_string();
                            if !text.is_empty() {
                                media.bridge.record("caller", &text);
                                media.bridge.inject(&text).await;
                            }
                        }
                    }
                }
                Some((_turn_id, reply)) = media.bridge.next_reply() => {
                    let spoken = strip_envelopes(&reply);
                    if spoken.is_empty() { continue; }
                    let mut tts = self.engine.tts("default", format)?;
                    let normalized = normalize_for_speech(&spoken);
                    for chunk in tts.push_text(&normalized).unwrap_or_default() {
                        media.audio.push_samples(&chunk.samples);
                    }
                    for chunk in tts.finish().unwrap_or_default() {
                        media.audio.push_samples(&chunk.samples);
                    }
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
            // The voice agent's `engine` block selects the provider (any
            // OpenAI-compatible base URL + models); no block = AI Gateway env.
            engine: OpenAiCompatEngine::from_config(params.get("engine"))?,
            format: AudioFormat::PCM_24K_MONO,
        }))
    }
}
