//! Deepgram STT adapter — a bespoke (non-OpenAI) provider shape.
//!
//! Batch REST: `POST {base}/listen?model=..&smart_format=true` with a WAV body
//! and `Authorization: Token <key>`; the transcript is
//! `results.channels[0].alternatives[0].transcript`. Streaming WS is a later
//! optimization; the batch path proves the adapter shape.

use anyhow::{anyhow, Context, Result};
use serde_json::Value;

use crate::http::{block_on, truncate};
use crate::stub::EnergyEndpointer;
use crate::wav::pcm_wav_bytes;
use crate::{
    AudioFormat, Endpointer, SttSession, TranscriptEvent, TtsSession, VoiceEngine,
};

fn default_base_url() -> String {
    "https://api.deepgram.com/v1".into()
}
fn default_model() -> String {
    "nova-3".into()
}

/// A [`VoiceEngine`] that only does STT (Deepgram has no TTS).
#[derive(Clone)]
pub struct DeepgramSttEngine {
    base_url: String,
    api_key: String,
    model: String,
    language: Option<String>,
    client: reqwest::Client,
}

impl DeepgramSttEngine {
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
            model: value
                .get("model")
                .or_else(|| value.get("stt_model"))
                .and_then(|v| v.as_str())
                .unwrap_or(&default_model())
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
            self.base_url, self.model, format.sample_rate, format.channels
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
}

impl VoiceEngine for DeepgramSttEngine {
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

    fn tts(&self, _voice: &str, _format: AudioFormat) -> Result<Box<dyn TtsSession>> {
        Err(anyhow!("deepgram provides STT only; pair it with a TTS provider"))
    }

    fn endpointer(&self, format: AudioFormat) -> Result<Box<dyn Endpointer>> {
        Ok(Box::new(EnergyEndpointer::new(format)))
    }
}

struct DeepgramStt {
    engine: DeepgramSttEngine,
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
