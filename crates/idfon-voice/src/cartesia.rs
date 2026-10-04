//! Cartesia TTS adapter — a bespoke (non-OpenAI) provider shape.
//!
//! REST: `POST {base}/tts/bytes` with `X-API-Key` + `Cartesia-Version` headers
//! and JSON `{ model_id, transcript, voice, output_format }`; the body is raw
//! s16le PCM when `output_format.container = "raw"`.

use anyhow::{anyhow, Context, Result};
use serde_json::Value;

use crate::http::{block_on, truncate};
use crate::stub::EnergyEndpointer;
use crate::{AudioFormat, Endpointer, PcmChunk, SttSession, TtsSession, VoiceEngine};

fn default_base_url() -> String {
    "https://api.cartesia.ai".into()
}
fn default_model() -> String {
    "sonic-2".into()
}
fn default_version() -> String {
    "2024-06-10".into()
}

/// A [`VoiceEngine`] that only does TTS.
#[derive(Clone)]
pub struct CartesiaTtsEngine {
    base_url: String,
    api_key: String,
    model: String,
    version: String,
    voice: String,
    language: String,
    client: reqwest::Client,
}

impl CartesiaTtsEngine {
    pub fn from_config(value: &Value) -> Result<Self> {
        let api_key_env = value
            .get("api_key_env")
            .and_then(|v| v.as_str())
            .unwrap_or("CARTESIA_API_KEY");
        let api_key = std::env::var(api_key_env)
            .ok()
            .filter(|key| !key.is_empty())
            .ok_or_else(|| anyhow!("{api_key_env} is required for Cartesia"))?;
        let voice = value
            .get("voice")
            .and_then(|v| v.as_str())
            .filter(|voice| !voice.is_empty() && *voice != "default")
            .ok_or_else(|| anyhow!("Cartesia needs a voice id (`voice`)"))?;
        Ok(Self {
            base_url: value
                .get("base_url")
                .and_then(|v| v.as_str())
                .unwrap_or(&default_base_url())
                .trim_end_matches('/')
                .to_string(),
            api_key,
            model: value
                .get("model")
                .or_else(|| value.get("tts_model"))
                .and_then(|v| v.as_str())
                .unwrap_or(&default_model())
                .to_string(),
            version: value
                .get("version")
                .and_then(|v| v.as_str())
                .unwrap_or(&default_version())
                .to_string(),
            voice: voice.to_string(),
            language: value
                .get("language")
                .and_then(|v| v.as_str())
                .unwrap_or("en")
                .to_string(),
            client: reqwest::Client::new(),
        })
    }

    fn speak(&self, voice: &str, format: AudioFormat, text: &str) -> Result<PcmChunk> {
        let voice = if voice.is_empty() || voice == "default" {
            self.voice.clone()
        } else {
            voice.to_string()
        };
        let url = format!("{}/tts/bytes", self.base_url);
        let api_key = self.api_key.clone();
        let version = self.version.clone();
        let model = self.model.clone();
        let language = self.language.clone();
        let text = text.to_string();
        let client = self.client.clone();
        block_on(async move {
            let response = client
                .post(&url)
                .header("x-api-key", api_key)
                .header("cartesia-version", version)
                .json(&serde_json::json!({
                    "model_id": model,
                    "transcript": text,
                    "voice": { "mode": "id", "id": voice },
                    "language": language,
                    "output_format": {
                        "container": "raw",
                        "encoding": "pcm_s16le",
                        "sample_rate": format.sample_rate,
                    },
                }))
                .send()
                .await
                .context("cartesia request")?;
            let status = response.status();
            let bytes = response.bytes().await.context("cartesia body")?;
            if !status.is_success() {
                let body = String::from_utf8_lossy(&bytes);
                return Err(anyhow!("cartesia HTTP {status}: {}", truncate(&body)));
            }
            let samples: Vec<i16> = bytes
                .chunks_exact(2)
                .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                .collect();
            Ok(PcmChunk { format, samples })
        })
    }
}

impl VoiceEngine for CartesiaTtsEngine {
    fn name(&self) -> &str {
        "cartesia"
    }

    fn stt(&self, _format: AudioFormat) -> Result<Box<dyn SttSession>> {
        Err(anyhow!("cartesia provides TTS only; pair it with an STT provider"))
    }

    fn tts(&self, voice: &str, format: AudioFormat) -> Result<Box<dyn TtsSession>> {
        Ok(Box::new(CartesiaTts {
            engine: self.clone(),
            format,
            voice: voice.to_string(),
            pending: String::new(),
        }))
    }

    fn endpointer(&self, format: AudioFormat) -> Result<Box<dyn Endpointer>> {
        Ok(Box::new(EnergyEndpointer::new(format)))
    }
}

struct CartesiaTts {
    engine: CartesiaTtsEngine,
    format: AudioFormat,
    voice: String,
    pending: String,
}

impl TtsSession for CartesiaTts {
    fn push_text(&mut self, delta: &str) -> Result<Vec<PcmChunk>> {
        self.pending.push_str(delta);
        let mut chunks = Vec::new();
        while let Some(index) = self
            .pending
            .char_indices()
            .find(|(_, c)| matches!(c, '.' | '!' | '?' | '\n'))
            .map(|(index, _)| index)
        {
            let sentence: String = self.pending.drain(..=index).collect();
            if !sentence.trim().is_empty() {
                chunks.push(self.engine.speak(&self.voice, self.format, &sentence)?);
            }
        }
        Ok(chunks)
    }

    fn finish(&mut self) -> Result<Vec<PcmChunk>> {
        let text = std::mem::take(&mut self.pending);
        if text.trim().is_empty() {
            return Ok(Vec::new());
        }
        Ok(vec![self.engine.speak(&self.voice, self.format, &text)?])
    }
}
