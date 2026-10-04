//! Cloud voice engine over an OpenAI-compatible AI Gateway.
//!
//! The holder process cannot reach the app's on-device Apple engine
//! (`idfon_voice_set_bindings` lives in the app process), so the server-side
//! cascade needs its own STT/TTS. This engine speaks to the same AI Gateway the
//! live voice path already uses, which makes it the zero-install demo
//! provider. It is a stopgap: the offline/local engines (Kyutai STT, Kokoro
//! TTS — see `docs/voice-side-channel.md`) remain the production target.
//!
//! Enable with the `gateway` feature. Config (env):
//! - `AI_GATEWAY_API_KEY` (required)
//! - `IDFON_VOICE_GATEWAY_URL` (default `https://ai-gateway.vercel.sh/v1`)
//! - `IDFON_STT_MODEL` (default `openai/whisper-1`)
//! - `IDFON_TTS_MODEL` (default `openai/tts-1`)
//! - `IDFON_TTS_VOICE` (default `alloy`)
//!
//! STT is batch (whole utterance on `flush`/`finish`); TTS is clause-batched so
//! an agent's streamed reply starts speaking before `finish`.

use anyhow::{anyhow, Context, Result};

use crate::stub::EnergyEndpointer;
use crate::wav::pcm_wav_bytes;
use crate::{
    AudioFormat, Endpointer, PcmChunk, SttSession, TranscriptEvent, TtsSession, VoiceEngine,
};

/// A [`VoiceEngine`] backed by an OpenAI-compatible gateway.
#[derive(Clone)]
pub struct GatewayVoiceEngine {
    base_url: String,
    api_key: String,
    stt_model: String,
    tts_model: String,
    tts_voice: String,
    client: reqwest::Client,
}

impl GatewayVoiceEngine {
    pub fn from_env() -> Result<Self> {
        let api_key = std::env::var("AI_GATEWAY_API_KEY")
            .ok()
            .filter(|key| !key.is_empty())
            .ok_or_else(|| anyhow!("AI_GATEWAY_API_KEY is required for the gateway voice engine"))?;
        Ok(Self {
            base_url: std::env::var("IDFON_VOICE_GATEWAY_URL")
                .unwrap_or_else(|_| "https://ai-gateway.vercel.sh/v1".into())
                .trim_end_matches('/')
                .to_string(),
            api_key,
            stt_model: std::env::var("IDFON_STT_MODEL").unwrap_or_else(|_| "openai/whisper-1".into()),
            tts_model: std::env::var("IDFON_TTS_MODEL").unwrap_or_else(|_| "openai/tts-1".into()),
            tts_voice: std::env::var("IDFON_TTS_VOICE").unwrap_or_else(|_| "alloy".into()),
            client: reqwest::Client::new(),
        })
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
        let url = format!("{}/audio/transcriptions", self.base_url);
        let wav = pcm_wav_bytes(format, pcm);
        let engine = self.clone();
        Self::block_on(async move {
            let part = reqwest::multipart::Part::bytes(wav)
                .file_name("audio.wav")
                .mime_str("audio/wav")?;
            let form = reqwest::multipart::Form::new()
                .part("file", part)
                .text("model", engine.stt_model.clone());
            let response = engine
                .client
                .post(&url)
                .bearer_auth(&engine.api_key)
                .multipart(form)
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
        let url = format!("{}/audio/speech", self.base_url);
        let engine = self.clone();
        let text = text.to_string();
        let voice = if voice.is_empty() || voice == "default" {
            self.tts_voice.clone()
        } else {
            voice.to_string()
        };
        Self::block_on(async move {
            let response = engine
                .client
                .post(&url)
                .bearer_auth(&engine.api_key)
                .json(&serde_json::json!({
                    "model": engine.tts_model,
                    "input": text,
                    "voice": voice,
                    "response_format": "pcm",
                }))
                .send()
                .await
                .context("speech request")?;
            let status = response.status();
            let bytes = response.bytes().await.context("speech body")?;
            if !status.is_success() {
                let body = String::from_utf8_lossy(&bytes);
                return Err(anyhow!("speech HTTP {status}: {}", truncate(&body)));
            }
            let samples: Vec<i16> = bytes
                .chunks_exact(2)
                .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                .collect();
            Ok(PcmChunk { format, samples })
        })
    }
}

impl VoiceEngine for GatewayVoiceEngine {
    fn name(&self) -> &str {
        "gateway"
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
    engine: GatewayVoiceEngine,
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
    engine: GatewayVoiceEngine,
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
    fn from_env_requires_a_key() {
        // Only assert the error shape when the key is genuinely absent.
        if std::env::var("AI_GATEWAY_API_KEY").is_err() {
            assert!(GatewayVoiceEngine::from_env().is_err());
        }
    }
}
