//! Deepgram STT + TTS adapter — a bespoke (non-OpenAI) provider shape.
//!
//! STT batch REST: `POST {base}/listen?...#encoding=linear16` with a WAV body
//! and `Authorization: Token <key>`; transcript at
//! `results.channels[0].alternatives[0].transcript`.
//! TTS batch REST: `POST {base}/speak?model=..&encoding=linear16&container=none`
//! with JSON `{text}`; the body is raw s16le PCM.

use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_websockets::{ClientBuilder, Message};

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
    /// Use the streaming WebSocket (partials, lower first-final latency)
    /// instead of batch REST. Opt-in via `"stream": true`.
    stream: bool,
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
            stream: value
                .get("stream")
                .or_else(|| value.get("stt_stream"))
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
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

    /// Open a streaming WebSocket session (opt-in via `"stream": true`).
    fn streaming_session(&self, format: AudioFormat) -> Result<StreamingDeepgramStt> {
        let mut url = format!(
            "wss://api.deepgram.com/v1/listen?model={}&encoding=linear16&sample_rate={}&channels={}&interim_results=true&smart_format=true",
            self.stt_model, format.sample_rate, format.channels
        );
        if let Some(language) = &self.language {
            url.push_str(&format!("&language={language}"));
        }
        let (control_tx, control_rx) = mpsc::unbounded_channel();
        let (event_tx, event_rx) = mpsc::unbounded_channel();
        let task = tokio::spawn(run_deepgram_stream(url, self.api_key.clone(), control_rx, event_tx));
        Ok(StreamingDeepgramStt {
            control: control_tx,
            events: event_rx,
            task,
            pending: String::new(),
        })
    }
}

enum StreamControl {
    Audio(Vec<i16>),
    Finalize,
    Close,
}

/// Streaming Deepgram STT: a background WS task forwards caller PCM and feeds
/// partial/final transcripts back. `flush` finalizes the current utterance and
/// returns every final accumulated since the last flush; the connection stays
/// open across turns.
pub struct StreamingDeepgramStt {
    control: mpsc::UnboundedSender<StreamControl>,
    events: mpsc::UnboundedReceiver<TranscriptEvent>,
    task: tokio::task::JoinHandle<()>,
    /// Final segments accumulated since the last `flush`. Deepgram finalizes
    /// (and emits `Final`) as it goes, not only on `Finalize`, so those finals
    /// must be kept — not dropped — or an utterance whose segments all
    /// finalized mid-speech flushes to nothing.
    pending: String,
}

impl SttSession for StreamingDeepgramStt {
    fn push(&mut self, pcm: &[i16]) -> Result<Vec<TranscriptEvent>> {
        let _ = self.control.send(StreamControl::Audio(pcm.to_vec()));
        let mut out = Vec::new();
        while let Ok(event) = self.events.try_recv() {
            match event {
                TranscriptEvent::Final(text) => self.pending.push_str(&text),
                partial @ TranscriptEvent::Partial(_) => out.push(partial),
            }
        }
        Ok(out)
    }

    fn flush(&mut self) -> Result<Option<String>> {
        let _ = self.control.send(StreamControl::Finalize);
        let events = &mut self.events;
        // Wait for the `from_finalize` final, bounded so a silent tail cannot
        // stall the turn; whatever already accumulated is returned regardless.
        let last = block_on(async move {
            tokio::time::timeout(Duration::from_millis(800), async {
                loop {
                    match events.recv().await {
                        Some(TranscriptEvent::Final(text)) => break Some(text),
                        Some(TranscriptEvent::Partial(_)) => continue,
                        None => break None,
                    }
                }
            })
            .await
            .unwrap_or(None)
        });
        if let Some(text) = last {
            self.pending.push_str(&text);
        }
        while let Ok(event) = self.events.try_recv() {
            if let TranscriptEvent::Final(text) = event {
                self.pending.push_str(&text);
            }
        }
        let text = std::mem::take(&mut self.pending).trim().to_string();
        if text.is_empty() {
            eprintln!("[idfon-voice] deepgram flush returned empty");
        }
        Ok((!text.is_empty()).then_some(text))
    }

    fn finish(&mut self) -> Result<Option<String>> {
        let _ = self.control.send(StreamControl::Close);
        let task = &mut self.task;
        block_on(async move {
            let _ = task.await;
        });
        Ok(None)
    }
}

async fn run_deepgram_stream(
    url: String,
    api_key: String,
    mut control: mpsc::UnboundedReceiver<StreamControl>,
    events: mpsc::UnboundedSender<TranscriptEvent>,
) {
    let uri = match url.parse() {
        Ok(uri) => uri,
        Err(error) => {
            eprintln!("[idfon-voice] deepgram stream url: {error}");
            return;
        }
    };
    let builder = match ClientBuilder::from_uri(uri)
        .add_header("authorization".parse().expect("header name"),
            format!("Token {api_key}").parse().expect("header value"))
    {
        Ok(builder) => builder,
        Err(error) => {
            eprintln!("[idfon-voice] deepgram stream header: {error}");
            return;
        }
    };
    let (mut ws, _) = match builder.connect().await {
        Ok(pair) => pair,
        Err(error) => {
            eprintln!("[idfon-voice] deepgram stream connect: {error}");
            return;
        }
    };
    eprintln!("[idfon-voice] deepgram stream connected");
    let mut open = true;
    while open {
        tokio::select! {
            control = control.recv() => match control {
                Some(StreamControl::Audio(pcm)) => {
                    let bytes: Vec<u8> = pcm.iter().flat_map(|sample| sample.to_le_bytes()).collect();
                    if ws.send(Message::binary(bytes)).await.is_err() {
                        break;
                    }
                }
                Some(StreamControl::Finalize) => {
                    let _ = ws.send(Message::text("{\"type\":\"Finalize\"}")).await;
                }
                Some(StreamControl::Close) | None => {
                    let _ = ws.send(Message::text("{\"type\":\"CloseStream\"}")).await;
                    open = false;
                }
            },
            message = ws.next() => match message {
                Some(Ok(message)) => {
                    if let Some(text) = message.as_text() {
                        handle_deepgram_event(text, &events);
                    }
                }
                Some(Err(error)) => {
                    eprintln!("[idfon-voice] deepgram stream read: {error}");
                    break;
                }
                None => break,
            }
        }
    }
    eprintln!("[idfon-voice] deepgram stream ended");
}

fn handle_deepgram_event(text: &str, events: &mpsc::UnboundedSender<TranscriptEvent>) {
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return;
    };
    if value["type"].as_str() != Some("Results") {
        return;
    }
    let transcript = value["channel"]["alternatives"][0]["transcript"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    if transcript.trim().is_empty() {
        return;
    }
    let is_final = value["is_final"].as_bool().unwrap_or(false)
        || value["speech_final"].as_bool().unwrap_or(false);
    let _ = events.send(if is_final {
        TranscriptEvent::Final(transcript)
    } else {
        TranscriptEvent::Partial(transcript)
    });
}

impl VoiceEngine for DeepgramEngine {
    fn name(&self) -> &str {
        "deepgram"
    }

    fn stt(&self, format: AudioFormat) -> Result<Box<dyn SttSession>> {
        if self.stream {
            return Ok(Box::new(self.streaming_session(format)?));
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Network smoke test: stream a 24 kHz s16 mono PCM file through the
    /// Deepgram WebSocket and print the transcript.
    ///
    /// `DEEPGRAM_API_KEY` + `IDFON_STT_TEST_PCM` (raw PCM path) required.
    /// `cargo test -p idfon-voice --features gateway deepgram_stream -- --ignored --nocapture`
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "network + DEEPGRAM_API_KEY"]
    async fn deepgram_stream_transcribes_speech() {
        let key = std::env::var("DEEPGRAM_API_KEY").unwrap_or_default();
        if key.is_empty() {
            return;
        }
        let path = std::env::var("IDFON_STT_TEST_PCM").expect("IDFON_STT_TEST_PCM");
        let bytes = std::fs::read(&path).expect("read pcm");
        let pcm: Vec<i16> = bytes
            .chunks_exact(2)
            .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
            .collect();
        let engine = DeepgramEngine::from_config(&serde_json::json!({
            "provider": "deepgram", "model": "nova-3", "stream": true
        }))
        .expect("engine");
        let format = AudioFormat::PCM_24K_MONO;
        let mut stt = engine.stt(format).expect("stt session");
        for frame in pcm.chunks(480) {
            let _ = stt.push(frame);
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let text = stt.flush().expect("flush");
        eprintln!("deepgram stream transcript = {text:?}");
        stt.finish().expect("finish");
        assert!(text.is_some(), "streaming STT returned no transcript");
    }
}
