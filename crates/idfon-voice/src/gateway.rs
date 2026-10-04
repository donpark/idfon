//! OpenAI-compatible voice engine: one adapter for many cloud/local providers.
//!
//! The vendor world mostly speaks the OpenAI audio API
//! (`POST {base}/audio/transcriptions` multipart + `POST {base}/audio/speech`
//! JSON→audio). Groq, Together, Fireworks, LocalAI, Speaches, Kokoro-FastAPI
//! and self-hosted `faster-whisper` shims all implement it, so a
//! [`Profile`] (base URL, key env, model/voice ids) covers them without new
//! code. Vendors that are *almost* compatible are handled by a profile too;
//! genuinely bespoke APIs (Deepgram/ElevenLabs streaming, etc.) get their own
//! adapter behind the same [`VoiceEngine`] seam.
//!
//! Enable with the `gateway` feature. Config (env, or a [`Profile`] from the
//! voice agent's `engine` block):
//! - `AI_GATEWAY_API_KEY` / `api_key_env` (required)
//! - `IDFON_VOICE_GATEWAY_URL` / `base_url` (default `https://ai-gateway.vercel.sh/v1`)
//! - `IDFON_STT_MODEL` / `stt_model` (default `openai/whisper-1`)
//! - `IDFON_TTS_MODEL` / `tts_model` (default `openai/tts-1`)
//! - `IDFON_TTS_VOICE` / `voice` (default `alloy`)

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use serde_json::Value;

use crate::stub::EnergyEndpointer;
use crate::wav::pcm_wav_bytes;
use crate::{
    AudioFormat, Endpointer, PcmChunk, SttSession, TranscriptEvent, TtsSession, VoiceEngine,
};

fn default_stt_model() -> String {
    "openai/whisper-1".into()
}
fn default_tts_model() -> String {
    "openai/tts-1".into()
}
fn default_voice() -> String {
    "alloy".into()
}
fn default_api_key_env() -> String {
    "AI_GATEWAY_API_KEY".into()
}
fn default_base_url() -> String {
    "https://ai-gateway.vercel.sh/v1".into()
}

/// A declarative OpenAI-compatible provider profile. Add a provider by adding
/// one of these (in config/env), not by writing code.
#[derive(Debug, Clone, Deserialize)]
pub struct Profile {
    #[serde(default = "default_base_url")]
    pub base_url: String,
    #[serde(default = "default_api_key_env")]
    pub api_key_env: String,
    #[serde(default = "default_stt_model")]
    pub stt_model: String,
    #[serde(default = "default_tts_model")]
    pub tts_model: String,
    #[serde(default = "default_voice")]
    pub voice: String,
    /// Response format requested from `audio/speech`. `pcm` is s16le 24 kHz.
    #[serde(default = "default_response_format")]
    pub response_format: String,
    /// Local servers (Kokoro, whisper shims) often need no auth: skip the
    /// bearer header and its key requirement when set.
    #[serde(default)]
    pub allow_missing_key: bool,
}

fn default_response_format() -> String {
    "pcm".into()
}

impl Profile {
    /// Build from the voice agent's `engine` config block, if it names a
    /// provider; otherwise fall back to the environment (AI Gateway defaults).
    pub fn from_value(engine: Option<&Value>) -> Result<Self> {
        let Some(engine) = engine.filter(|value| !value.is_null()) else {
            return Self::from_env();
        };
        // A named `provider` other than an OpenAI-compatible one is handled by
        // a different adapter; this engine only builds compatible profiles.
        if let Some(provider) = engine.get("provider").and_then(|value| value.as_str()) {
            if provider != "openai" && provider != "openai-compatible" {
                return Err(anyhow!(
                    "provider '{provider}' is not an OpenAI-compatible engine"
                ));
            }
        }
        serde_json::from_value(engine.clone()).context("parse OpenAI-compatible engine profile")
    }

    /// Environment-driven profile (the AI Gateway defaults).
    pub fn from_env() -> Result<Self> {
        let api_key_env = std::env::var("IDFON_VOICE_API_KEY_ENV")
            .unwrap_or_else(|_| default_api_key_env());
        if std::env::var(&api_key_env)
            .ok()
            .filter(|key| !key.is_empty())
            .is_none()
        {
            return Err(anyhow!("{api_key_env} is required for the voice engine"));
        }
        Ok(Self {
            base_url: std::env::var("IDFON_VOICE_GATEWAY_URL")
                .unwrap_or_else(|_| default_base_url()),
            api_key_env,
            stt_model: std::env::var("IDFON_STT_MODEL").unwrap_or_else(|_| default_stt_model()),
            tts_model: std::env::var("IDFON_TTS_MODEL").unwrap_or_else(|_| default_tts_model()),
            voice: std::env::var("IDFON_TTS_VOICE").unwrap_or_else(|_| default_voice()),
            response_format: std::env::var("IDFON_TTS_FORMAT")
                .unwrap_or_else(|_| default_response_format()),
            allow_missing_key: false,
        })
    }

    fn api_key(&self) -> Result<String> {
        match std::env::var(&self.api_key_env)
            .ok()
            .filter(|key| !key.is_empty())
        {
            Some(key) => Ok(key),
            None if self.allow_missing_key => Ok(String::new()),
            None => Err(anyhow!("{} is required for the voice engine", self.api_key_env)),
        }
    }
}

/// A [`VoiceEngine`] over any OpenAI-compatible audio API.
#[derive(Clone)]
pub struct OpenAiCompatEngine {
    profile: Profile,
    client: reqwest::Client,
}

/// Back-compat alias for the engine introduced as the AI Gateway engine.
pub type GatewayVoiceEngine = OpenAiCompatEngine;

impl OpenAiCompatEngine {
    pub fn new(profile: Profile) -> Self {
        Self {
            profile,
            client: reqwest::Client::new(),
        }
    }

    /// Build from the environment (AI Gateway defaults).
    pub fn from_env() -> Result<Self> {
        Ok(Self::new(Profile::from_env()?))
    }

    /// Build for one call from the voice agent's config; falls back to env.
    pub fn from_config(engine: Option<&Value>) -> Result<Self> {
        Ok(Self::new(Profile::from_value(engine)?))
    }

    pub fn provider(&self) -> &str {
        &self.profile.base_url
    }

    /// Bridge a sync trait method to the async HTTP client. The holder runs a
    /// multi-thread runtime, so `block_in_place` is safe; outside a runtime
    /// (tests) we build a small one.
    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        match tokio::runtime::Handle::try_current() {
            Ok(handle) => tokio::task::block_in_place(|| handle.block_on(future)),
            Err(_) => tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build gateway runtime")
                .block_on(future),
        }
    }

    fn transcribe(&self, format: AudioFormat, pcm: &[i16]) -> Result<String> {
        let base = self.profile.base_url.trim_end_matches('/').to_string();
        let url = format!("{base}/audio/transcriptions");
        let model = self.profile.stt_model.clone();
        let api_key = self.profile.api_key()?;
        let wav = pcm_wav_bytes(format, pcm);
        let client = self.client.clone();
        Self::block_on(async move {
            let part = reqwest::multipart::Part::bytes(wav)
                .file_name("audio.wav")
                .mime_str("audio/wav")?;
            let form = reqwest::multipart::Form::new()
                .part("file", part)
                .text("model", model);
            let mut request = client.post(&url).multipart(form);
            if !api_key.is_empty() {
                request = request.bearer_auth(&api_key);
            }
            let response = request
                .send()
                .await
                .context("transcription request")?;
            let status = response.status();
            let body = response.text().await.context("transcription body")?;
            if !status.is_success() {
                return Err(anyhow!("transcription HTTP {status}: {}", truncate(&body)));
            }
            let value: serde_json::Value =
                serde_json::from_str(&body).context("transcription JSON")?;
            Ok(value
                .get("text")
                .and_then(|text| text.as_str())
                .unwrap_or_default()
                .to_string())
        })
    }

    fn synthesize(&self, voice: &str, format: AudioFormat, text: &str) -> Result<PcmChunk> {
        let base = self.profile.base_url.trim_end_matches('/').to_string();
        let url = format!("{base}/audio/speech");
        let model = self.profile.tts_model.clone();
        let response_format = self.profile.response_format.clone();
        let api_key = self.profile.api_key()?;
        let text = text.to_string();
        let voice = if voice.is_empty() || voice == "default" {
            self.profile.voice.clone()
        } else {
            voice.to_string()
        };
        let client = self.client.clone();
        Self::block_on(async move {
            let mut request = client.post(&url).json(&serde_json::json!({
                "model": model,
                "input": text,
                "voice": voice,
                "response_format": response_format,
            }));
            if !api_key.is_empty() {
                request = request.bearer_auth(&api_key);
            }
            let response = request
                .send()
                .await
                .context("speech request")?;
            let status = response.status();
            let bytes = response.bytes().await.context("speech body")?;
            if !status.is_success() {
                let body = String::from_utf8_lossy(&bytes);
                return Err(anyhow!("speech HTTP {status}: {}", truncate(&body)));
            }
            // `pcm` is s16le at the requested format; other formats would need
            // decoding (an adapter concern, added per provider as needed).
            let samples: Vec<i16> = bytes
                .chunks_exact(2)
                .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                .collect();
            Ok(PcmChunk { format, samples })
        })
    }
}

impl VoiceEngine for OpenAiCompatEngine {
    fn name(&self) -> &str {
        "openai-compatible"
    }

    fn stt(&self, format: AudioFormat) -> Result<Box<dyn SttSession>> {
        Ok(Box::new(GatewayStt {
            engine: self.clone(),
            format,
            pcm: Vec::new(),
        }))
    }

    fn tts(&self, voice: &str, format: AudioFormat) -> Result<Box<dyn TtsSession>> {
        Ok(Box::new(GatewayTts {
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

/// Batch STT: buffers the utterance; the endpointer/`flush` closes the turn.
struct GatewayStt {
    engine: OpenAiCompatEngine,
    format: AudioFormat,
    pcm: Vec<i16>,
}

impl SttSession for GatewayStt {
    fn push(&mut self, pcm: &[i16]) -> Result<Vec<TranscriptEvent>> {
        self.pcm.extend_from_slice(pcm);
        Ok(Vec::new())
    }

    fn flush(&mut self) -> Result<Option<String>> {
        let pcm = std::mem::take(&mut self.pcm);
        if pcm.is_empty() {
            return Ok(None);
        }
        let text = self.engine.transcribe(self.format, &pcm)?;
        Ok(if text.trim().is_empty() {
            None
        } else {
            Some(text)
        })
    }

    fn finish(&mut self) -> Result<Option<String>> {
        self.flush()
    }
}

/// Clause-batched TTS: each complete sentence is synthesized as it arrives.
struct GatewayTts {
    engine: OpenAiCompatEngine,
    format: AudioFormat,
    voice: String,
    pending: String,
}

impl TtsSession for GatewayTts {
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
                chunks.push(self.engine.synthesize(&self.voice, self.format, &sentence)?);
            }
        }
        Ok(chunks)
    }

    fn finish(&mut self) -> Result<Vec<PcmChunk>> {
        let text = std::mem::take(&mut self.pending);
        if text.trim().is_empty() {
            return Ok(Vec::new());
        }
        Ok(vec![self.engine.synthesize(&self.voice, self.format, &text)?])
    }
}

fn truncate(text: &str) -> String {
    const MAX: usize = 200;
    if text.len() <= MAX {
        return text.to_string();
    }
    format!("{}…", &text[..MAX])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_caps_error_bodies() {
        assert_eq!(truncate("short"), "short");
        assert!(truncate(&"x".repeat(500)).chars().count() <= 201);
    }

    #[test]
    fn profile_from_config_names_provider() {
        let profile = Profile::from_value(Some(&serde_json::json!({
            "provider": "openai-compatible",
            "base_url": "https://api.groq.com/openai/v1",
            "api_key_env": "GROQ_API_KEY",
            "stt_model": "whisper-large-v3",
            "tts_model": "playai-tts",
            "voice": "Aaliyah-PlayAI",
        })))
        .unwrap();
        assert_eq!(profile.base_url, "https://api.groq.com/openai/v1");
        assert_eq!(profile.stt_model, "whisper-large-v3");
        assert_eq!(profile.response_format, "pcm");
    }

    #[test]
    fn profile_rejects_non_compatible_provider() {
        assert!(Profile::from_value(Some(&serde_json::json!({ "provider": "deepgram" }))).is_err());
    }

    #[test]
    fn from_env_requires_a_key() {
        if std::env::var("AI_GATEWAY_API_KEY").is_err() {
            assert!(OpenAiCompatEngine::from_env().is_err());
        }
    }
}
