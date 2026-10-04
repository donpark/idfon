//! Deepgram STT + TTS adapter — a bespoke (non-OpenAI) provider shape.
//!
//! STT batch REST: `POST {base}/listen?...#encoding=linear16` with a WAV body
//! and `Authorization: Token <key>`; transcript at
//! `results.channels[0].alternatives[0].transcript`.
//! TTS batch REST: `POST {base}/speak?model=..&encoding=linear16&container=none`
//! with JSON `{text}`; the body is raw s16le PCM.

use anyhow::{anyhow, Context, Result};
use serde_json::Value;

use crate::http::{block_on, truncate};
use crate::stub::EnergyEndpointer;
use crate::wav::pcm_wav_bytes;
use crate::{
    AudioFormat, Endpointer, PcmChunk, SttSession, TranscriptEvent, TtsSession, VoiceEngine,
};

fn default_base_url() -> String {
    "https://api.deepgram.com/v1".into()
}
fn default_stt_model() -> String {
    "nova-3".into()
}
fn default_tts_voice() -> String {
    "aura-asteria-en".into()
}

/// A [`VoiceEngine`] for Deepgram: STT (`listen`) and TTS (`speak`).
#[derive(Clone)]
pub struct DeepgramEngine {
    base_url: String,
    api_key: String,
    stt_model: String,
    voice: String,
    language: Option<String>,
    client: reqwest::Client,
}

impl DeepgramEngine {
    pub fn from_config(value: &Value) -> Result<Self> {
        let api_key_env = value
            .get("api_key_env")
            .and_then(|v| v.as_str())
            .unwrap_or("DEEPGRAM_API_KEY");
        let api_key = std::env::var(api_key_env)
            .ok()
            .filter(|key| !key.is_empty())
            .ok_or_else(|| anyhow!("{api_key_env} is required for Deepgram"))?;
        Ok(Self {
            base_url: value
                .get("base_url")
                .and_then(|v| v.as_str())
                .unwrap_or(&default_base_url())
                .trim_end_matches('/')
                .to_string(),
            api_key,
            stt_model: value
                .get("model")
                .or_else(|| value.get("stt_model"))
                .and_then(|v| v.as_str())
                .unwrap_or(&default_stt_model())
                .to_string(),
            voice: value
                .get("voice")
                .or_else(|| value.get("tts_model"))
                .and_then(|v| v.as_str())
                .filter(|voice| !voice.is_empty() && *voice != "default")
                .unwrap_or(&default_tts_voice())
                .to_string(),
            language: value
                .get("language")
                .and_then(|v| v.as_str())
                .map(str::to_owned),
            client: reqwest::Client::new(),
        })
    }

    fn transcribe(&self, format: AudioFormat, pcm: &[i16]) -> Result<String> {
        let mut url = format!(
            "{}/listen?model={}&smart_format=true&encoding=linear16&sample_rate={}&channels={}",
            self.base_url, self.stt_model, format.sample_rate, format.channels
        );
        if let Some(language) = &self.language {
            url.push_str(&format!("&language={language}"));
        }
        let api_key = self.api_key.clone();
        let wav = pcm_wav_bytes(format, pcm);
        let client = self.client.clone();
        block_on(async move {
            let response = client
                .post(&url)
                .header("authorization", format!("Token {api_key}"))
                .header("content-type", "audio/wav")
                .body(wav)
                .send()
                .await
                .context("deepgram request")?;
            let status = response.status();
            let body = response.text().await.context("deepgram body")?;
            if !status.is_success() {
                return Err(anyhow!("deepgram HTTP {status}: {}", truncate(&body)));
            }
            let value: Value = serde_json::from_str(&body).context("deepgram JSON")?;
            Ok(value["results"]["channels"][0]["alternatives"][0]["transcript"]
                .as_str()
                .unwrap_or_default()
                .to_string())
        })
    }

    fn speak(&self, voice: &str, format: AudioFormat, text: &str) -> Result<PcmChunk> {
        let voice = if voice.is_empty() || voice == "default" {
            self.voice.clone()
        } else {
            voice.to_string()
        };
        let url = format!(
            "{}/speak?model={}&encoding=linear16&sample_rate={}&container=none",
            self.base_url, voice, format.sample_rate
        );
        let api_key = self.api_key.clone();
        let text = text.to_string();
        let client = self.client.clone();
        block_on(async move {
            let response = client
                .post(&url)
                .header("authorization", format!("Token {api_key}"))
                .header("content-type", "application/json")
                .json(&serde_json::json!({ "text": text }))
                .send()
                .await
                .context("deepgram speak request")?;
            let status = response.status();
            let bytes = response.bytes().await.context("deepgram speak body")?;
            if !status.is_success() {
                let body = String::from_utf8_lossy(&bytes);
                return Err(anyhow!("deepgram speak HTTP {status}: {}", truncate(&body)));
            }
            let samples: Vec<i16> = bytes
                .chunks_exact(2)
                .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                .collect();
            Ok(PcmChunk { format, samples })
        })
    }
}

impl VoiceEngine for DeepgramEngine {
    fn name(&self) -> &str {
        "deepgram"
    }

    fn stt(&self, format: AudioFormat) -> Result<Box<dyn SttSession>> {
        Ok(Box::new(DeepgramStt {
            engine: self.clone(),
            format,
            pcm: Vec::new(),
        }))
    }

    fn tts(&self, voice: &str, format: AudioFormat) -> Result<Box<dyn TtsSession>> {
        Ok(Box::new(DeepgramTts {
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

struct DeepgramStt {
    engine: DeepgramEngine,
    format: AudioFormat,
    pcm: Vec<i16>,
}

impl SttSession for DeepgramStt {
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

/// Clause-batched Deepgram TTS.
struct DeepgramTts {
    engine: DeepgramEngine,
    format: AudioFormat,
    voice: String,
    pending: String,
}

impl TtsSession for DeepgramTts {
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
