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

use crate::deepgram::DeepgramSttEngine;
use crate::elevenlabs::ElevenLabsTtsEngine;
use crate::gateway::OpenAiCompatEngine;
use crate::{AudioFormat, Endpointer, SttSession, TtsSession, VoiceEngine};

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
        "deepgram" => Ok(Arc::new(DeepgramSttEngine::from_config(value)?)),
        "elevenlabs" => Ok(Arc::new(ElevenLabsTtsEngine::from_config(value)?)),
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

    fn endpointer(&self, format: AudioFormat) -> Result<Box<dyn Endpointer>> {
        self.stt.endpointer(format)
    }
}
