//! ElevenLabs TTS adapter — a bespoke (non-OpenAI) provider shape.
//!
//! Batch REST: `POST {base}/text-to-speech/{voice_id}?output_format=pcm_24000`
//! with `xi-api-key` and JSON `{text, model_id}`; the body is raw s16le PCM.

use anyhow::{anyhow, Context, Result};
use futures_util::StreamExt;
use serde_json::Value;

use crate::http::{block_on, truncate};
use crate::stub::EnergyEndpointer;
use crate::{AudioFormat, AudioSink, Endpointer, PcmChunk, SttSession, TtsSession, VoiceEngine};

fn default_base_url() -> String {
    "https://api.elevenlabs.io/v1".into()
}
fn default_model() -> String {
    "eleven_turbo_v2_5".into()
}

/// A [`VoiceEngine`] that only does TTS (ElevenLabs has no STT here).
#[derive(Clone)]
pub struct ElevenLabsTtsEngine {
    base_url: String,
    api_key: String,
    model: String,
    voice: String,
    client: reqwest::Client,
}

impl ElevenLabsTtsEngine {
    pub fn from_config(value: &Value) -> Result<Self> {
        let api_key_env = value
            .get("api_key_env")
            .and_then(|v| v.as_str())
            .unwrap_or("ELEVENLABS_API_KEY");
        let api_key = std::env::var(api_key_env)
            .ok()
            .filter(|key| !key.is_empty())
            .ok_or_else(|| anyhow!("{api_key_env} is required for ElevenLabs"))?;
        let voice = value
            .get("voice")
            .and_then(|v| v.as_str())
            .filter(|voice| !voice.is_empty() && *voice != "default")
            .ok_or_else(|| anyhow!("ElevenLabs needs a voice id (`voice`)"))?;
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
            voice: voice.to_string(),
            client: reqwest::Client::new(),
        })
    }

    /// Streaming: POST the clause to `/stream` and forward PCM chunks to the
    /// sink as they arrive, so speech starts before synthesis completes.
    async fn stream_speak(
        &self,
        voice: &str,
        format: AudioFormat,
        text: &str,
        sink: &AudioSink,
    ) -> Result<()> {
        let voice_id = if voice.is_empty() || voice == "default" {
            self.voice.clone()
        } else {
            voice.to_string()
        };
        let url = format!(
            "{}/text-to-speech/{}/stream?output_format=pcm_{}",
            self.base_url, voice_id, format.sample_rate
        );
        let response = self
            .client
            .post(&url)
            .header("xi-api-key", &self.api_key)
            .json(&serde_json::json!({ "text": text, "model_id": self.model }))
            .send()
            .await
            .context("elevenlabs stream request")?;
        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(anyhow!("elevenlabs stream HTTP {status}: {}", truncate(&body)));
        }
        let mut stream = response.bytes_stream();
        let mut carry: Vec<u8> = Vec::new();
        while let Some(chunk) = stream.next().await {
            let bytes = chunk.context("elevenlabs stream chunk")?;
            carry.extend_from_slice(&bytes);
            let usable = carry.len() - (carry.len() % 2);
            if usable == 0 {
                continue;
            }
            let samples: Vec<i16> = carry[..usable]
                .chunks_exact(2)
                .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                .collect();
            carry.drain(..usable);
            sink(PcmChunk { format, samples });
        }
        Ok(())
    }

    fn speak(&self, voice: &str, format: AudioFormat, text: &str) -> Result<PcmChunk> {
        let voice_id = if voice.is_empty() || voice == "default" {
            self.voice.clone()
        } else {
            voice.to_string()
        };
        let url = format!(
            "{}/text-to-speech/{}?output_format=pcm_{}",
            self.base_url, voice_id, format.sample_rate
        );
        let api_key = self.api_key.clone();
        let model = self.model.clone();
        let text = text.to_string();
        let client = self.client.clone();
        block_on(async move {
            let response = client
                .post(&url)
                .header("xi-api-key", api_key)
                .json(&serde_json::json!({ "text": text, "model_id": model }))
                .send()
                .await
                .context("elevenlabs request")?;
            let status = response.status();
            let bytes = response.bytes().await.context("elevenlabs body")?;
            if !status.is_success() {
                let body = String::from_utf8_lossy(&bytes);
                return Err(anyhow!("elevenlabs HTTP {status}: {}", truncate(&body)));
            }
            let samples: Vec<i16> = bytes
                .chunks_exact(2)
                .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                .collect();
            Ok(PcmChunk { format, samples })
        })
    }
}

impl VoiceEngine for ElevenLabsTtsEngine {
    fn name(&self) -> &str {
        "elevenlabs"
    }

    fn stt(&self, _format: AudioFormat) -> Result<Box<dyn SttSession>> {
        Err(anyhow!("elevenlabs provides TTS only; pair it with an STT provider"))
    }

    fn tts(&self, voice: &str, format: AudioFormat) -> Result<Box<dyn TtsSession>> {
        Ok(Box::new(ElevenLabsTts {
            engine: self.clone(),
            format,
            voice: voice.to_string(),
            pending: String::new(),
        }))
    }

    fn tts_with_sink(
        &self,
        voice: &str,
        format: AudioFormat,
        sink: AudioSink,
    ) -> Result<Box<dyn TtsSession>> {
        Ok(Box::new(StreamingElevenLabsTts::new(
            self.clone(),
            format,
            voice.to_string(),
            sink,
        )))
    }

    fn endpointer(&self, format: AudioFormat) -> Result<Box<dyn Endpointer>> {
        Ok(Box::new(EnergyEndpointer::new(format)))
    }
}

/// Streaming session: clauses go to a single worker that synthesizes them **in
/// order**, streaming each to the sink. A task *per clause* is wrong here —
/// concurrent syntheses interleave their PCM and a multi-clause reply plays on
/// top of itself.
struct StreamingElevenLabsTts {
    tx: Option<tokio::sync::mpsc::UnboundedSender<String>>,
    worker: Option<tokio::task::JoinHandle<()>>,
}

impl StreamingElevenLabsTts {
    fn new(
        engine: ElevenLabsTtsEngine,
        format: AudioFormat,
        voice: String,
        sink: AudioSink,
    ) -> Self {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        let worker = tokio::spawn(async move {
            while let Some(text) = rx.recv().await {
                if let Err(error) = engine.stream_speak(&voice, format, &text, &sink).await {
                    eprintln!("[idfon-voice] elevenlabs stream failed: {error}");
                }
            }
        });
        Self {
            tx: Some(tx),
            worker: Some(worker),
        }
    }
}

impl TtsSession for StreamingElevenLabsTts {
    fn push_text(&mut self, delta: &str) -> Result<Vec<PcmChunk>> {
        if delta.trim().is_empty() {
            return Ok(Vec::new());
        }
        if let Some(tx) = &self.tx {
            let _ = tx.send(delta.to_string());
        }
        Ok(Vec::new())
    }

    fn finish(&mut self) -> Result<Vec<PcmChunk>> {
        // Close the queue and wait for the worker to drain every clause.
        drop(self.tx.take());
        if let Some(worker) = self.worker.take() {
            block_on(async move {
                let _ = worker.await;
            });
        }
        Ok(Vec::new())
    }
}

struct ElevenLabsTts {
    engine: ElevenLabsTtsEngine,
    format: AudioFormat,
    voice: String,
    pending: String,
}

impl TtsSession for ElevenLabsTts {
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
