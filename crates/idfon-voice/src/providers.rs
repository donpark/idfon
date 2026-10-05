//! Provider registry: build a [`VoiceEngine`] from a voice agent's config.
//!
//! Two config shapes:
//!
//! ```json
//! { "provider": "openai-compatible", "base_url": "...", "stt_model": "...", "tts_model": "..." }
//! ```
//!
//! or a split, to mix providers (e.g. Deepgram STT + ElevenLabs TTS):
//!
//! ```json
//! { "stt": { "provider": "deepgram", "model": "nova-3" },
//!   "tts": { "provider": "elevenlabs", "voice": "..." } }
//! ```
#![cfg(feature = "gateway")]

use std::sync::Arc;

use anyhow::{anyhow, Result};
use serde_json::Value;

use crate::cartesia::CartesiaTtsEngine;
use crate::deepgram::DeepgramEngine;
use crate::elevenlabs::ElevenLabsTtsEngine;
use crate::gateway::{OpenAiCompatEngine, Profile};
use crate::process::ProcessVoiceEngine;
use crate::{AudioFormat, AudioSink, Endpointer, SttSession, TtsSession, VoiceEngine};

/// Build the engine for one voice agent from its `engine` config block.
pub fn build_engine(engine: Option<&Value>) -> Result<Arc<dyn VoiceEngine>> {
    let Some(engine) = engine.filter(|value| !value.is_null()) else {
        // No config: the AI Gateway defaults from the environment.
        return Ok(Arc::new(OpenAiCompatEngine::from_env()?));
    };
    if let Some(stt) = engine.get("stt") {
        let tts = engine
            .get("tts")
            .ok_or_else(|| anyhow!("split engine config needs both `stt` and `tts`"))?;
        return Ok(Arc::new(CompositeVoiceEngine {
            stt: build_provider(stt)?,
            tts: build_provider(tts)?,
        }));
    }
    build_provider(engine)
}

fn build_provider(value: &Value) -> Result<Arc<dyn VoiceEngine>> {
    let provider = value
        .get("provider")
        .and_then(|v| v.as_str())
        .unwrap_or("openai-compatible");
    match provider {
        "openai" | "openai-compatible" => Ok(Arc::new(OpenAiCompatEngine::new(
            crate::gateway::Profile::from_value(Some(value))?,
        ))),
        "deepgram" => Ok(Arc::new(DeepgramEngine::from_config(value)?)),
        "elevenlabs" => Ok(Arc::new(ElevenLabsTtsEngine::from_config(value)?)),
        "cartesia" => Ok(Arc::new(CartesiaTtsEngine::from_config(value)?)),
        // Local command engine: wire any CLI (Kokoro, Whistle, Parakeet, …).
        "command" | "local" => Ok(Arc::new(ProcessVoiceEngine::from_config(
            value,
            AudioFormat::PCM_24K_MONO,
        )?)),
        // Kokoro served by its OpenAI-compatible server (kokoro-fastapi) on
        // localhost, no API key. `stt` falls back to the same server's ASR.
        "kokoro" => Ok(Arc::new(OpenAiCompatEngine::new(kokoro_profile(value)?))),
        other => Err(anyhow!("unknown voice provider '{other}'")),
    }
}

/// STT from one provider, TTS from another — the common mix-and-match case.
pub struct CompositeVoiceEngine {
    stt: Arc<dyn VoiceEngine>,
    tts: Arc<dyn VoiceEngine>,
}

impl VoiceEngine for CompositeVoiceEngine {
    fn name(&self) -> &str {
        // Name is only used for logs; a split engine is two providers.
        "composite"
    }

    fn stt(&self, format: AudioFormat) -> Result<Box<dyn SttSession>> {
        self.stt.stt(format)
    }

    fn tts(&self, voice: &str, format: AudioFormat) -> Result<Box<dyn TtsSession>> {
        self.tts.tts(voice, format)
    }

    fn tts_with_sink(
        &self,
        voice: &str,
        format: AudioFormat,
        sink: AudioSink,
    ) -> Result<Box<dyn TtsSession>> {
        // Forward so a split config keeps the provider's streaming TTS
        // (e.g. ElevenLabs `/stream`); the default would fall back to batch.
        self.tts.tts_with_sink(voice, format, sink)
    }

    fn endpointer(&self, format: AudioFormat) -> Result<Box<dyn Endpointer>> {
        self.stt.endpointer(format)
    }
}

/// Kokoro/OpenAI-compatible local server defaults, overlaid by config. Kokoro
/// is typically served by `kokoro-fastapi`, which exposes the OpenAI audio API
/// on localhost and needs no key.
fn kokoro_profile(value: &Value) -> Result<Profile> {
    let mut merged = serde_json::json!({
        "provider": "openai-compatible",
        "base_url": "http://127.0.0.1:8880/v1",
        "stt_model": "Systran/faster-whisper-small",
        "tts_model": "kokoro",
        "voice": "af_bella",
        "allow_missing_key": true,
    });
    if let (Some(base), Some(config)) = (merged.as_object_mut(), value.as_object()) {
        for (key, item) in config {
            base.insert(key.clone(), item.clone());
        }
    }
    Profile::from_value(Some(&merged))
}
