//! GPT-Live full-duplex backend (feature `gpt-live`).
//!
//! One of several engines a voice agent can run (see `docs/voice-agent.md`);
//! the server-side cascade is another. This backend opens an OpenAI
//! `gpt-live-1` Live-API session over the shared live-media transport: caller
//! audio in, spoken reply out, with deep work delegated to the Eve agent.
//!
//! It is a [`VoiceBackend`], so it inherits the shared call lifecycle
//! (`CallSession`, caller subscribe/pacing, return-leg audio, stop) and only
//! owns the vendor protocol. Named after the **API**, not the vendor: OpenAI's
//! Realtime API is a different protocol and would be a sibling backend
//! (`openai-realtime`), not a rename of this one.

use std::{
    collections::VecDeque,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use eve_idfon::{records, IpcFrame, ReplyTarget};
use futures_util::{SinkExt, StreamExt};
use idfon_core::transport::MessageTransport;
use idfon_live_media::{rand_suffix, AudioProfile};
use idfon_protocol::{CallSpeaker, CallTranscript, MessageContent};
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_websockets::{ClientBuilder, Message};

use crate::{BackendFuture, CallPlatform, VoiceBackend, VoiceBackendFactory, VoiceMedia};

const SESSION_CLOSE_TIMEOUT: Duration = Duration::from_secs(15);
// Transcript streaming: a new turn starts on a speaker switch or a pause this
// long; snapshots are sent at most this often so a turn is a few messages, not
// one per delta.
const TRANSCRIPT_TURN_GAP: Duration = Duration::from_millis(1200);
const TRANSCRIPT_SNAPSHOT: Duration = Duration::from_millis(400);
const TRANSCRIPT_MAX_CHARS: usize = 2000;

/// Agent/channel configuration for the GPT-Live backend. Every value the
/// platform must not know lives here; defaults keep the demo working with no
/// config, and `serve --live-config FILE` (channel config) overrides them.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(default)]
pub struct GptLiveConfig {
    /// Live-session WebSocket endpoint.
    pub live_url: String,
    /// Voice model id sent in `session.start`.
    pub model: String,
    /// Optional voice id; omitted from the request when unset.
    pub voice: Option<String>,
    /// Environment variable holding the provider credential.
    pub api_key_env: String,
    /// Persona/instructions for the live session.
    pub instructions: String,
    /// MoQ broadcast name for the holder side of the call.
    pub broadcast: String,
    /// Provenance tag for delegated turns injected into the agent.
    pub source: String,
    /// Template for a delegated request. `{said}` is the caller transcript.
    pub delegation_request: String,
    /// One spoken-turn cap in seconds.
    pub reply_max_seconds: u64,
}

impl Default for GptLiveConfig {
    fn default() -> Self {
        Self {
            live_url: "wss://ai-gateway.vercel.sh/v1/live/sessions".into(),
            model: "openai/gpt-live-1".into(),
            voice: None,
            api_key_env: "AI_GATEWAY_API_KEY".into(),
            instructions: "You are on a live phone call with one person. \
                 Greet them briefly when the call connects, then converse naturally. \
                 Keep spoken turns short and conversational, like a phone call. \
                 If the caller asks for something to look at - a written explanation, \
                 report, diagram, chart, or web page - briefly say you are putting it \
                 together, then delegate it; the assistant builds it and sends it to \
                 their chat. Plain speech only: no markdown, no lists, no emoji."
                .into(),
            broadcast: "idfon-live-agent".into(),
            source: "gpt-live-delegation".into(),
            delegation_request: "[live voice call] The caller said: \"{said}\". Build what they asked for now; if it is something to look at (an explanation, report, diagram, chart, or web page), publish it with add_artifact and keep the spoken reply brief.".into(),
            reply_max_seconds: 120,
        }
    }
}

impl GptLiveConfig {
    /// Build from the opaque channel metadata handed to the backend.
    pub fn from_params(params: &Value) -> Self {
        serde_json::from_value(params.clone()).unwrap_or_default()
    }
}

/// Builds the GPT-Live backend; unavailable (so the call falls through to a
/// text turn) when the provider key is not in the holder environment.
pub struct GptLiveFactory;

impl VoiceBackendFactory for GptLiveFactory {
    fn kind(&self) -> &str {
        "gpt-live"
    }

    fn create(&self, params: &Value) -> Result<Box<dyn VoiceBackend>> {
        let config = GptLiveConfig::from_params(params);
        let key = std::env::var(&config.api_key_env).unwrap_or_default();
        if key.is_empty() {
            anyhow::bail!("{} is not set", config.api_key_env);
        }
        Ok(Box::new(GptLiveBackend { config }))
    }
}

/// Full-duplex GPT-Live session for one call.
pub struct GptLiveBackend {
    config: GptLiveConfig,
}

impl VoiceBackend for GptLiveBackend {
    fn name(&self) -> &str {
        "gpt-live"
    }

    fn run(&mut self, media: VoiceMedia) -> BackendFuture<'_> {
        Box::pin(self.run_loop(media))
    }
}

impl GptLiveBackend {
    async fn run_loop(&mut self, media: VoiceMedia) -> Result<()> {
        let config = self.config.clone();
        let api_key = std::env::var(&config.api_key_env)
            .ok()
            .filter(|key| !key.is_empty())
            .ok_or_else(|| anyhow!("{} is not set", config.api_key_env))?;
        let VoiceMedia {
            caller,
            audio,
            stop,
            profile,
            platform,
            ..
        } = media;
        let CallPlatform {
            transport,
            key,
            holder_endpoint_id,
            caller_addr,
            caller_peer_id,
            targets,
            out_tx,
        } = platform;

        // Delegated deep work from the live session runs as a normal Eve turn:
        // register a reply target per request so the agent's reply (text + any
        // `IDFON-ARTIFACT/1` envelope) routes to the caller, while the stripped
        // text also reaches the live session's commentary.
        let (delegation_tx, mut delegation_rx) = mpsc::unbounded_channel::<Delegation>();
        {
            let peer_id = caller_peer_id.clone();
            let endpoint_id = caller_addr.id.to_string();
            let source = config.source.clone();
            tokio::spawn(async move {
                while let Some(delegation) = delegation_rx.recv().await {
                    let reply_key = format!("{peer_id}:live-delegation-{}", delegation.delegation_id);
                    targets.lock().await.insert(
                        reply_key.clone(),
                        ReplyTarget {
                            peer_id: peer_id.clone(),
                            endpoint_id: endpoint_id.clone(),
                            conversation: None,
                            a2a_depth: None,
                            live_commentary: Some((delegation.delegation_id.clone(), delegation.reply)),
                            // Delegated turn keeps its chat reply too.
                            live_only: false,
                        },
                    );
                    let frame = IpcFrame::TurnIn {
                        message_id: reply_key,
                        peer_id: peer_id.clone(),
                        endpoint_id: endpoint_id.clone(),
                        idempotency_key: format!("live-delegation-{}", delegation.delegation_id),
                        conversation: None,
                        text: delegation.request,
                        blob_ticket: None,
                        size_bytes: None,
                        a2a_depth: None,
                        capabilities: None,
                        source: Some(source.clone()),
                    };
                    if out_tx.send(frame).await.is_err() {
                        break;
                    }
                }
            });
        }

        let ws = connect_live(&api_key, &config).await?;
        let (mut ws_tx, mut ws_rx) = ws.split();
        eprintln!("[voice-agent] GPT-Live session ready peer={caller_peer_id}");

        let call_started = Instant::now();
        let turn_count = Arc::new(AtomicU64::new(0));
        let call_id = rand_suffix();
        // Delegated replies arrive as `(delegation_id, spoken_text)` and are fed
        // to GPT-Live as commentary by the task that owns `ws_tx`.
        let (commentary_tx, commentary_rx) = mpsc::unbounded_channel::<(String, String)>();
        // Transcript snapshots are signed and sent off the reader loop so a slow
        // send cannot stall audio; one task preserves snapshot order. Finals are
        // also written to the durable voice-record buffer keyed by the caller
        // (P0: recording never triggers an Eve turn).
        let (transcript_tx, mut transcript_rx) = mpsc::unbounded_channel::<CallTranscript>();
        // Spoken copies of delegated replies: GPT-Live reads them back as output
        // transcripts, which must not be recorded as a second copy of a reply
        // the Eve agent already wrote into its own history.
        let delegated_spoken: Arc<Mutex<VecDeque<String>>> = Arc::new(Mutex::new(VecDeque::new()));
        let transcript_task = {
            let transport = Arc::clone(&transport);
            let key = key.clone();
            let holder_endpoint_id = holder_endpoint_id.clone();
            let caller_addr = caller_addr.clone();
            let caller_peer_id = caller_peer_id.clone();
            let delegated_spoken = Arc::clone(&delegated_spoken);
            let turn_count = Arc::clone(&turn_count);
            tokio::spawn(async move {
                let mut seq = 0u64;
                while let Some(transcript) = transcript_rx.recv().await {
                    if transcript.r#final {
                        turn_count.fetch_add(1, Ordering::Relaxed);
                        let speaker = match transcript.role {
                            CallSpeaker::Caller => "caller",
                            CallSpeaker::Agent => "agent",
                        };
                        if speaker == "agent"
                            && take_delegated_spoken(&delegated_spoken, &transcript.text)
                        {
                            continue;
                        }
                        records::store().append(
                            &caller_peer_id,
                            records::VoiceRecord::transcript(
                                &transcript.call_id,
                                speaker,
                                &transcript.text,
                            ),
                        );
                    }
                    seq += 1;
                    let Ok(text) = idfon_protocol::encode_call_transcript(&transcript) else {
                        continue;
                    };
                    let message_id = format!("eve_call_transcript_{}_{}", transcript.turn_id, seq);
                    let envelope = match idfon_core::sign_message(
                        &key,
                        holder_endpoint_id.clone(),
                        message_id.clone(),
                        MessageContent::Text { text },
                        format!("{message_id}-{}", u8::from(transcript.r#final)),
                        None,
                    ) {
                        Ok(envelope) => envelope,
                        Err(error) => {
                            eprintln!("[voice-agent] call transcript sign failed: {error}");
                            continue;
                        }
                    };
                    if let Err(error) = transport.send(&caller_addr, &envelope).await {
                        eprintln!("[voice-agent] call transcript send failed: {error}");
                    }
                }
            })
        };

        // WS → broadcast: decode base64 s16 24 kHz chunks straight into the queue.
        let reader_stop = Arc::clone(&stop);
        let reader_audio = audio.clone();
        let session_finalized = Arc::new(AtomicBool::new(false));
        let reader_finalized = Arc::clone(&session_finalized);
        let reader_commentary = commentary_tx.clone();
        let reader_call_id = call_id.clone();
        let reader_config = config.clone();
        let mut reader = tokio::spawn(async move {
            let mut output_chunks = 0usize;
            let mut output_bytes = 0usize;
            let mut input_text_chars = 0usize;
            let mut output_text_chars = 0usize;
            let mut finalized = false;
            let mut stream = TranscriptStream::new(reader_call_id);
            while let Some(event) = ws_rx.next().await {
                let message = match event {
                    Ok(message) => message,
                    Err(error) => {
                        eprintln!("[voice-agent] GPT-Live websocket read failed: {error}");
                        break;
                    }
                };
                let Some(text) = message.as_text() else {
                    continue;
                };
                let Ok(event) = serde_json::from_str::<serde_json::Value>(text) else {
                    eprintln!("[voice-agent] ignored non-JSON GPT-Live event");
                    continue;
                };
                match event["type"].as_str().unwrap_or_default() {
                    "session.input_transcript.delta" => {
                        let delta = event["delta"].as_str().unwrap_or_default();
                        input_text_chars += delta.len();
                        stream.push(CallSpeaker::Caller, delta, &transcript_tx);
                        eprintln!("[voice-agent] GPT-Live input transcript chars={input_text_chars}");
                    }
                    "session.output_transcript.delta" => {
                        let delta = event["delta"].as_str().unwrap_or_default();
                        output_text_chars += delta.len();
                        stream.push(CallSpeaker::Agent, delta, &transcript_tx);
                        eprintln!("[voice-agent] GPT-Live output transcript chars={output_text_chars}");
                    }
                    "session.delegation.created" => {
                        let delegation_id = event["delegation"]["id"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string();
                        if !delegation_id.is_empty() {
                            let said = stream.latest_caller_text();
                            let request = reader_config.delegation_request.replace("{said}", &said);
                            let _ = delegation_tx.send(Delegation {
                                delegation_id,
                                request,
                                reply: reader_commentary.clone(),
                            });
                            eprintln!("[voice-agent] live delegation dispatched");
                        }
                    }
                    "session.output_audio.delta" => {
                        if let Some(delta) =
                            event["delta"].as_str().and_then(|d| BASE64.decode(d).ok())
                        {
                            output_chunks += 1;
                            output_bytes += delta.len();
                            reader_audio.push_bytes(&delta);
                            if output_chunks == 1 || output_chunks % 50 == 0 {
                                eprintln!("[voice-agent] GPT-Live audio out chunks={output_chunks} bytes={output_bytes}");
                            }
                        }
                    }
                    "session.closed" => {
                        finalized = true;
                        reader_finalized.store(true, Ordering::Relaxed);
                        eprintln!(
                            "[voice-agent] GPT-Live session closed usage={} reason={}",
                            event["usage"],
                            event["reason"].as_str().unwrap_or("(none)"),
                        );
                        break;
                    }
                    "error" => {
                        eprintln!("[voice-agent] GPT-Live error: {}", event["error"]);
                        break;
                    }
                    _ => {}
                }
            }
            stream.flush(true, &transcript_tx);
            reader_stop.store(true, Ordering::Relaxed);
            eprintln!(
                "[voice-agent] GPT-Live reader done finalized={finalized} audio_chunks={output_chunks} audio_bytes={output_bytes} input_text_chars={input_text_chars} output_text_chars={output_text_chars}"
            );
            finalized
        });

        // Caller audio → WS; on hangup, cancel the pump and close GPT-Live cleanly.
        let pacer_stop = Arc::clone(&stop);
        let pacer_finalized = Arc::clone(&session_finalized);
        let reply_max_seconds = config.reply_max_seconds;
        let mut pacer = tokio::spawn(async move {
            let pump_stop = Arc::clone(&pacer_stop);
            let result = tokio::select! {
                _ = async {
                    while !pacer_stop.load(Ordering::Relaxed) {
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                } => Ok(()),
                result = pump_caller_audio(caller, &mut ws_tx, pump_stop, profile, reply_max_seconds, commentary_rx, Arc::clone(&delegated_spoken)) => result,
            };
            if let Err(error) = result {
                eprintln!("[voice-agent] caller audio ended: {error:#}");
            }
            if !pacer_finalized.load(Ordering::Relaxed) {
                let close = Message::text(json!({"type": "session.close"}).to_string());
                match tokio::time::timeout(Duration::from_secs(2), ws_tx.send(close)).await {
                    Ok(Ok(())) => eprintln!("[voice-agent] GPT-Live session.close sent"),
                    Ok(Err(error)) => {
                        eprintln!("[voice-agent] GPT-Live session.close failed: {error}")
                    }
                    Err(_) => eprintln!("[voice-agent] GPT-Live session.close timed out"),
                }
            }
            pacer_stop.store(true, Ordering::Relaxed);
        });

        let finalized = tokio::select! {
            result = &mut reader => {
                stop.store(true, Ordering::Relaxed);
                if let Err(error) = tokio::time::timeout(Duration::from_secs(2), &mut pacer).await {
                    eprintln!("[voice-agent] audio pump cleanup timed out: {error}");
                    pacer.abort();
                }
                match result {
                    Ok(finalized) => finalized,
                    Err(error) => {
                        eprintln!("[voice-agent] GPT-Live reader task failed: {error}");
                        false
                    }
                }
            }
            result = &mut pacer => {
                if let Err(error) = result {
                    eprintln!("[voice-agent] caller audio task failed: {error}");
                }
                match tokio::time::timeout(SESSION_CLOSE_TIMEOUT, &mut reader).await {
                    Ok(Ok(finalized)) => finalized,
                    Ok(Err(error)) => {
                        eprintln!("[voice-agent] GPT-Live reader task failed: {error}");
                        false
                    }
                    Err(_) => {
                        eprintln!("[voice-agent] GPT-Live close timed out; dropping websocket reader");
                        reader.abort();
                        let _ = reader.await;
                        false
                    }
                }
            }
        };
        // Let the transcript task finish the queue (its sender lives in the
        // reader task, which has ended) so the hangup summary is recorded last.
        let _ = tokio::time::timeout(Duration::from_secs(5), transcript_task).await;
        records::store().append(
            &caller_peer_id,
            records::VoiceRecord::call_summary(
                &call_id,
                call_started.elapsed().as_secs(),
                turn_count.load(Ordering::Relaxed),
            ),
        );
        if !finalized {
            eprintln!("[voice-agent] GPT-Live finalization unconfirmed");
        }
        Ok(())
    }
}

/// A deep-work request emitted by GPT-Live during a live call. The holder
/// forwards it to the Eve agent (which owns `add_artifact`); `reply` carries
/// `(delegation_id, spoken_text)` back to the live session's commentary so the
/// voice model can say the result.
pub struct Delegation {
    pub delegation_id: String,
    pub request: String,
    pub reply: mpsc::UnboundedSender<(String, String)>,
}

/// Coalesces GPT-Live transcript deltas into per-turn snapshots.
struct TranscriptStream {
    call_id: String,
    speaker: Option<CallSpeaker>,
    turn_id: String,
    text: String,
    turn_seq: u64,
    last_delta: Option<Instant>,
    last_snapshot: Option<Instant>,
    last_caller_text: String,
}

impl TranscriptStream {
    fn new(call_id: String) -> Self {
        Self {
            turn_id: format!("{call_id}-0"),
            call_id,
            speaker: None,
            text: String::new(),
            turn_seq: 0,
            last_delta: None,
            last_snapshot: None,
            last_caller_text: String::new(),
        }
    }

    fn push(
        &mut self,
        speaker: CallSpeaker,
        delta: &str,
        out: &mpsc::UnboundedSender<CallTranscript>,
    ) {
        let now = Instant::now();
        let gap = self
            .last_delta
            .map(|last| now.duration_since(last))
            .unwrap_or(TRANSCRIPT_TURN_GAP);
        let switched = self.speaker != Some(speaker);
        if (switched || gap > TRANSCRIPT_TURN_GAP) && !self.text.is_empty() {
            self.flush(true, out);
            self.turn_seq += 1;
            self.turn_id = format!("{}-{}", self.call_id, self.turn_seq);
        }
        self.speaker = Some(speaker);
        self.text.push_str(delta);
        while self.text.len() > TRANSCRIPT_MAX_CHARS {
            let mut boundary = self.text.len() - TRANSCRIPT_MAX_CHARS;
            while !self.text.is_char_boundary(boundary) {
                boundary += 1;
            }
            self.text.drain(..boundary);
        }
        self.last_delta = Some(now);
        if speaker == CallSpeaker::Caller {
            self.last_caller_text = self.text.clone();
        }
        let due = self
            .last_snapshot
            .map(|last| now.duration_since(last) >= TRANSCRIPT_SNAPSHOT)
            .unwrap_or(true);
        if due {
            self.flush(false, out);
        }
    }

    fn latest_caller_text(&self) -> String {
        self.last_caller_text.trim().to_string()
    }

    fn flush(&mut self, r#final: bool, out: &mpsc::UnboundedSender<CallTranscript>) {
        if self.text.is_empty() {
            return;
        }
        let speaker = self.speaker.unwrap_or(CallSpeaker::Caller);
        let transcript = match speaker {
            CallSpeaker::Caller => {
                CallTranscript::caller(&self.call_id, &self.turn_id, &self.text, r#final)
            }
            CallSpeaker::Agent => {
                CallTranscript::agent(&self.call_id, &self.turn_id, &self.text, r#final)
            }
        };
        let _ = out.send(transcript);
        self.last_snapshot = Some(Instant::now());
        if r#final {
            self.text.clear();
        }
    }
}

/// Opens the live session for one call.
async fn connect_live(
    api_key: &str,
    config: &GptLiveConfig,
) -> Result<
    tokio_websockets::WebSocketStream<tokio_websockets::MaybeTlsStream<tokio::net::TcpStream>>,
> {
    eprintln!("[voice-agent] connecting to live session");
    let builder = ClientBuilder::from_uri(config.live_url.parse().context("parse live url")?)
        .add_header(
            "authorization".parse().context("header name")?,
            format!("Bearer {api_key}")
                .parse()
                .context("header value")?,
        )
        .context("auth header")?;
    let (mut ws, _response) = builder.connect().await.context("connect live session")?;
    let mut audio = json!({ "format": { "type": "audio/pcm", "rate": 24_000 } });
    if let Some(voice) = &config.voice {
        audio["voice"] = json!(voice);
    }
    ws.send(Message::text(
        json!({
            "type": "session.start",
            "session": {
                "model": config.model,
                "store": false,
                "delegation": { "type": "client" },
                "audio": audio,
                "instructions": config.instructions,
            },
        })
        .to_string(),
    ))
    .await
    .context("send session.start")?;
    tokio::time::timeout(Duration::from_secs(15), async {
        while let Some(message) = ws.next().await {
            let message = message.context("read live startup event")?;
            let Some(text) = message.as_text() else {
                continue;
            };
            let event: serde_json::Value =
                serde_json::from_str(text).context("parse live startup event")?;
            match event["type"].as_str().unwrap_or_default() {
                "session.started" => return Ok::<(), anyhow::Error>(()),
                "error" => anyhow::bail!("live session.start rejected: {}", event["error"]),
                "session.closed" => anyhow::bail!("live session closed during session.start"),
                _ => {}
            }
        }
        anyhow::bail!("live websocket closed before session.started")
    })
    .await
    .context("live session.start timed out")??;
    eprintln!("[voice-agent] live session.started");
    Ok(ws)
}

/// Forwards the caller's paced frames to GPT-Live and its delegated commentary
/// back into the session.
async fn pump_caller_audio<S>(
    mut frames: mpsc::Receiver<Vec<i16>>,
    ws_tx: &mut S,
    stop: Arc<AtomicBool>,
    profile: AudioProfile,
    reply_max_seconds: u64,
    mut commentary_rx: mpsc::UnboundedReceiver<(String, String)>,
    delegated_spoken: Arc<Mutex<VecDeque<String>>>,
) -> Result<()>
where
    S: futures_util::Sink<Message> + Unpin + Send,
    S::Error: std::fmt::Display,
{
    let rate = profile.sample_rate.max(1) as u64;
    let mut chunks = 0u64;
    let mut sent_samples = 0u64;
    loop {
        tokio::select! {
            item = frames.recv() => {
                let Some(pcm) = item else { break };
                let bytes: Vec<u8> = pcm.iter().flat_map(|sample| sample.to_le_bytes()).collect();
                ws_tx
                    .send(Message::text(json!({
                        "type": "session.input_audio.append",
                        "audio": BASE64.encode(&bytes),
                    }).to_string()))
                    .await
                    .map_err(|error| anyhow!("GPT-Live send: {error}"))?;
                chunks += 1;
                sent_samples += pcm.len() as u64;
                if chunks == 1 || chunks % 50 == 0 {
                    eprintln!("[voice-agent] caller appends={chunks}");
                }
                if sent_samples >= reply_max_seconds.max(1) * rate { break; }
            }
            Some((delegation_id, content)) = commentary_rx.recv() => {
                note_delegated_spoken(&delegated_spoken, &content);
                ws_tx
                    .send(Message::text(json!({
                        "type": "session.commentary.append",
                        "content": content,
                        "delegation_id": delegation_id,
                    }).to_string()))
                    .await
                    .map_err(|error| anyhow!("GPT-Live commentary send: {error}"))?;
            }
        }
        if stop.load(Ordering::Relaxed) {
            break;
        }
    }
    Ok(())
}

/// Whitespace-normalized text for comparing a delegated reply with GPT-Live's
/// spoken readback of it.
fn normalize_spoken(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn note_delegated_spoken(pending: &Mutex<VecDeque<String>>, text: &str) {
    let normalized = normalize_spoken(text);
    if normalized.is_empty() {
        return;
    }
    if let Ok(mut queue) = pending.lock() {
        queue.push_back(normalized);
        while queue.len() > 8 {
            queue.pop_front();
        }
    }
}

/// True when `spoken` is GPT-Live reading back a delegated reply; consumes the
/// matching pending entry so a repeated phrase is not dropped twice.
fn take_delegated_spoken(pending: &Mutex<VecDeque<String>>, spoken: &str) -> bool {
    let normalized = normalize_spoken(spoken);
    if normalized.is_empty() {
        return false;
    }
    let head = |text: &str| text.chars().take(48).collect::<String>();
    if let Ok(mut queue) = pending.lock() {
        let hit = queue.iter().position(|candidate| {
            candidate == &normalized
                || normalized.starts_with(&head(candidate))
                || candidate.starts_with(&head(&normalized))
        });
        if let Some(index) = hit {
            queue.remove(index);
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use idfon_live_media::parse_invite;
    use iroh::EndpointId;

    #[test]
    fn config_defaults_and_channel_overrides() {
        let defaults = GptLiveConfig::from_params(&serde_json::Value::Null);
        assert_eq!(defaults.model, "openai/gpt-live-1");
        assert_eq!(defaults.api_key_env, "AI_GATEWAY_API_KEY");
        assert_eq!(defaults.broadcast, "idfon-live-agent");
        let overridden = GptLiveConfig::from_params(&serde_json::json!({
            "model": "vendor/other",
            "live_url": "wss://example.test/live",
            "api_key_env": "OTHER_KEY",
            "voice": "verse",
            "reply_max_seconds": 30,
        }));
        assert_eq!(overridden.model, "vendor/other");
        assert_eq!(overridden.live_url, "wss://example.test/live");
        assert_eq!(overridden.api_key_env, "OTHER_KEY");
        assert_eq!(overridden.voice.as_deref(), Some("verse"));
        assert_eq!(overridden.reply_max_seconds, 30);
    }

    #[test]
    fn checked_in_channel_config_parses() {
        // Guards the channel-config projection the serve script forwards.
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../agents/live-voice/live.json"
        );
        let raw = std::fs::read_to_string(path).expect("read live.json");
        let config: GptLiveConfig = serde_json::from_str(&raw).expect("parse live.json");
        assert_eq!(config.model, "openai/gpt-live-1");
        assert_eq!(config.broadcast, "idfon-live-agent");
        assert!(!config.instructions.is_empty());
    }

    #[test]
    fn delegated_reply_readback_is_dropped_once() {
        let pending = Arc::new(Mutex::new(VecDeque::new()));
        note_delegated_spoken(&pending, "  Two plus two is four.  ");
        // Whitespace-normalized readback matches and is consumed once.
        assert!(take_delegated_spoken(&pending, "Two plus two is four."));
        assert!(!take_delegated_spoken(&pending, "Two plus two is four."));
        // An unrelated caller utterance is never dropped.
        assert!(!take_delegated_spoken(&pending, "What time is it?"));
    }

    #[test]
    fn transcript_stream_coalesces_turns() {
        let (tx, mut rx) = mpsc::unbounded_channel::<CallTranscript>();
        let mut stream = TranscriptStream::new("call-0".into());
        stream.push(CallSpeaker::Caller, "Hello", &tx);
        stream.push(CallSpeaker::Caller, " world", &tx);
        stream.push(CallSpeaker::Agent, "Hi there", &tx);
        stream.flush(true, &tx);
        drop(tx);
        let mut snapshots = Vec::new();
        while let Ok(item) = rx.try_recv() {
            snapshots.push(item);
        }
        assert!(snapshots
            .iter()
            .any(|t| t.role == CallSpeaker::Caller && t.text == "Hello world" && t.r#final));
        assert!(snapshots
            .iter()
            .any(|t| t.role == CallSpeaker::Agent && t.text == "Hi there" && t.r#final));
        assert!(snapshots.iter().all(|t| t.call_id == "call-0"));
        // The caller turn and agent turn get distinct ids.
        let caller_turn = snapshots
            .iter()
            .find(|t| t.role == CallSpeaker::Caller)
            .unwrap();
        let agent_turn = snapshots
            .iter()
            .find(|t| t.role == CallSpeaker::Agent)
            .unwrap();
        assert_ne!(caller_turn.turn_id, agent_turn.turn_id);
    }

    #[test]
    fn parses_caller_return_address() {
        let id: EndpointId = "508fd877b2d8e41b3d70100d0bdecd275fbd7e09f63f6c41dba5c327c791b188"
            .parse()
            .unwrap();
        let address = iroh::EndpointAddr::new(id);
        let encoded = BASE64.encode(serde_json::to_vec(&address).unwrap());
        let invite = parse_invite(&format!(
            "IDFON-LIVE/1\naction=start\nticket=ticket\nreturn_addr={encoded}"
        ))
        .unwrap();
        assert_eq!(invite.return_addr.unwrap().id, id);
    }
}
