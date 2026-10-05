//! Voice-agent kit: one config-driven runner, pluggable voice backends.
//!
//! A **voice agent** is an idfon peer that gives a text-first agent a voice
//! (see `docs/voice-agent.md`). This crate owns the parts every voice agent
//! shares — the holder handler, the live-media session, and the turn bridge —
//! and delegates the audio↔text work to a [`VoiceBackend`]. Adding a voice
//! agent is a config (+ an Eve agent dir); adding an engine is one backend.
//!
//! Backends: [`cascade`] (STT → agent → TTS). GPT-Live (full-duplex) and local
//! engines plug in the same way.

use std::{
    collections::HashMap,
    future::Future,
    pin::Pin,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
};

use anyhow::{anyhow, Context, Result};
use ed25519_dalek::SigningKey;
use eve_idfon::{
    live::{LiveCallContext, LiveCallFuture, LiveCallHandler, AUDIO_PUBLISH},
    records, IpcFrame, ReplyTarget, Targets,
};
use idfon_core::transport::{IrohTransport, MessageTransport};
use idfon_protocol::{CallSpeaker, CallTranscript, MessageContent};
use idfon_live_media::{
    parse_audio_profile, parse_invite, rand_suffix, subscribe_caller, AudioProfile, AudioQueue,
    CallSession,
};
use iroh::{EndpointAddr, EndpointId};
use serde_json::Value;
use tokio::sync::mpsc;

pub mod cascade;
#[cfg(feature = "gpt-live")]
pub mod gpt_live;
pub mod metrics;
pub mod relay;
pub use cascade::CascadeFactory;
#[cfg(feature = "gpt-live")]
pub use gpt_live::GptLiveFactory;
pub use relay::RelayFactory;

/// The async result of running one backend for one call.
pub type BackendFuture<'a> = Pin<Box<dyn Future<Output = Result<()>> + Send + 'a>>;

/// One voice engine behind the voice-agent seam.
///
/// A backend owns one call's audio loop; it may be duplex (a model session) or
/// cascade (STT + agent turn + TTS). The shared media session and turn bridge
/// are handed to it in [`VoiceMedia`].
pub trait VoiceBackend: Send {
    fn name(&self) -> &str;
    fn run(&mut self, media: VoiceMedia) -> BackendFuture<'_>;
}

/// Creates a backend for one call from the voice agent's config.
pub trait VoiceBackendFactory: Send + Sync {
    /// Config key that selects this backend (`engine.kind` / `backend`).
    fn kind(&self) -> &str;
    fn create(&self, params: &Value) -> Result<Box<dyn VoiceBackend>>;
}

/// Everything a backend needs for one call.
pub struct VoiceMedia {
    /// Caller audio as paced 20 ms, 24 kHz mono frames.
    pub caller: mpsc::Receiver<Vec<i16>>,
    /// Caller transcripts injected by the app when it runs STT on-device
    /// (`voice_route.stt = client`); the backend skips its own STT then.
    pub caller_text: mpsc::UnboundedReceiver<String>,
    /// Agent-output deltas (F11) routed from the holder, for incremental TTS.
    pub deltas: mpsc::UnboundedReceiver<eve_idfon::deltas::Delta>,
    /// Return-leg audio the backend renders for the caller.
    pub audio: AudioQueue,
    pub stop: Arc<AtomicBool>,
    pub profile: AudioProfile,
    pub bridge: TurnBridge,
    /// Platform primitives a duplex backend needs to sign/send its own call
    /// envelopes (transcripts) and to inject delegated turns directly.
    pub platform: CallPlatform,
}

/// Platform services shared with the holder, for backends that don't route
/// everything through [`TurnBridge`] (e.g. a full-duplex model that emits its
/// own `IDFON-CALL/1` transcript snapshots and delegation turns).
pub struct CallPlatform {
    pub transport: Arc<IrohTransport>,
    pub key: SigningKey,
    pub holder_endpoint_id: String,
    pub caller_addr: EndpointAddr,
    pub caller_peer_id: String,
    pub targets: Targets,
    pub out_tx: mpsc::Sender<IpcFrame>,
}

/// Sign and send one `IDFON-CALL/1` transcript envelope to the caller so the
/// chat view renders the spoken bubble (parity with `gpt_live`). Best-effort:
/// a send failure must not disturb audio.
pub async fn send_call_transcript(
    platform: &CallPlatform,
    call_id: &str,
    role: CallSpeaker,
    turn_id: &str,
    text: &str,
    r#final: bool,
) {
    let transcript = CallTranscript {
        call_id: call_id.to_string(),
        turn_id: turn_id.to_string(),
        role,
        text: text.to_string(),
        r#final,
    };
    let Ok(text) = idfon_protocol::encode_call_transcript(&transcript) else {
        return;
    };
    let message_id = format!("eve_call_transcript_{}_{}", turn_id, rand_suffix());
    let envelope = match idfon_core::sign_message(
        &platform.key,
        platform.holder_endpoint_id.clone(),
        message_id.clone(),
        MessageContent::Text { text },
        format!("{message_id}-{}", u8::from(r#final)),
        None,
    ) {
        Ok(envelope) => envelope,
        Err(error) => {
            eprintln!("[voice-agent] call transcript sign failed: {error}");
            return;
        }
    };
    if let Err(error) = platform.transport.send(&platform.caller_addr, &envelope).await {
        eprintln!("[voice-agent] call transcript send failed: {error}");
    }
}

/// The shared text hop: inject a caller transcript as a normal agent turn and
/// receive the agent's reply text for the backend to speak.
pub struct TurnBridge {
    peer_id: String,
    endpoint_id: String,
    source: String,
    targets: Targets,
    out_tx: mpsc::Sender<IpcFrame>,
    reply_tx: mpsc::UnboundedSender<(String, String)>,
    replies: mpsc::UnboundedReceiver<(String, String)>,
    call_id: String,
}

impl TurnBridge {
    pub fn new(
        peer_id: String,
        endpoint_id: String,
        source: String,
        targets: Targets,
        out_tx: mpsc::Sender<IpcFrame>,
    ) -> Self {
        let (reply_tx, replies) = mpsc::unbounded_channel();
        Self {
            peer_id,
            endpoint_id,
            source,
            targets,
            out_tx,
            reply_tx,
            replies,
            call_id: rand_suffix(),
        }
    }

    /// Inject one caller transcript as an agent turn; returns the turn id.
    pub async fn inject(&self, text: &str) -> String {
        let turn_id = format!("voice_{}", rand_suffix());
        self.targets.lock().await.insert(
            turn_id.clone(),
            ReplyTarget {
                peer_id: self.peer_id.clone(),
                endpoint_id: self.endpoint_id.clone(),
                conversation: None,
                a2a_depth: None,
                live_commentary: Some((turn_id.clone(), self.reply_tx.clone())),
                // Voice turn: speak it, don't post a text copy to the caller.
                live_only: true,
            },
        );
        let sent = self
            .out_tx
            .send(IpcFrame::TurnIn {
                message_id: turn_id.clone(),
                peer_id: self.peer_id.clone(),
                endpoint_id: self.endpoint_id.clone(),
                idempotency_key: turn_id.clone(),
                conversation: None,
                text: text.to_string(),
                blob_ticket: None,
                size_bytes: None,
                a2a_depth: None,
                capabilities: None,
                source: Some(self.source.clone()),
            })
            .await
            .is_ok();
        eprintln!("[voice-agent] inject turn={turn_id} sent={sent} text={text:?}");
        turn_id
    }

    /// Next agent reply (turn id, text) routed back to this call.
    pub async fn next_reply(&mut self) -> Option<(String, String)> {
        self.replies.recv().await
    }

    pub fn peer_id(&self) -> &str {
        &self.peer_id
    }

    /// Forward one caller PCM frame to the bridge (SSE subscribers), for a
    /// standalone TypeScript voice agent to transcribe.
    pub async fn send_frame(&self, pcm: &[i16]) {
        use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
        let bytes: Vec<u8> = pcm.iter().flat_map(|sample| sample.to_le_bytes()).collect();
        let _ = self
            .out_tx
            .send(IpcFrame::AudioFrameOut {
                peer_id: self.peer_id.clone(),
                pcm_base64: BASE64.encode(&bytes),
            })
            .await;
    }

    /// Append a durable transcript record for the caller or the agent.
    pub fn record(&self, speaker: &str, text: &str) {
        records::store().append(
            &self.peer_id,
            records::VoiceRecord::transcript(&self.call_id, speaker, text),
        );
    }

    /// Record what the caller had heard before a barge-in cancelled playback
    /// (F6/P4): the truncated agent turn id and the text played so far.
    pub fn record_playback_truncated(&self, msg_id: &str, heard_until: &str) {
        records::store().append(
            &self.peer_id,
            records::VoiceRecord::playback_truncated(&self.call_id, msg_id, heard_until),
        );
    }

    pub fn call_id(&self) -> &str {
        &self.call_id
    }
}

/// Voice-agent config, read from the live config (`--live-config`).
#[derive(Debug, Clone)]
pub struct VoiceAgentConfig {
    /// Backend kind to run (`cascade`, later `gpt-live`, …).
    pub backend: String,
    /// MoQ broadcast name for the return leg.
    pub broadcast: String,
    /// Provenance tag on injected turns.
    pub source: String,
    /// Who runs STT: `true` = holder, `false` = caller (on-device).
    pub stt_server: bool,
    /// Who runs TTS: `true` = holder, `false` = caller (on-device).
    pub tts_server: bool,
}

impl VoiceAgentConfig {
    pub fn from_params(params: &Value) -> Self {
        // Hybrid ownership comes from the signed `voice_route` block; absent,
        // the holder does both halves (the original server-cascade).
        let route = params
            .get("voice_route")
            .and_then(|value| serde_json::from_value::<idfon_protocol::VoiceRoute>(value.clone()).ok());
        let (stt_server, tts_server) = match route {
            Some(route) => (
                route.stt_side() == idfon_protocol::VoiceHalf::Server,
                route.tts_side() == idfon_protocol::VoiceHalf::Server,
            ),
            None => (true, true),
        };
        Self {
            backend: params
                .get("backend")
                .or_else(|| params.get("engine").and_then(|engine| engine.get("kind")))
                .and_then(|value| value.as_str())
                .unwrap_or("cascade")
                .to_string(),
            broadcast: params
                .get("broadcast")
                .and_then(|value| value.as_str())
                .unwrap_or("idfon-voice-agent")
                .to_string(),
            source: params
                .get("source")
                .and_then(|value| value.as_str())
                .unwrap_or("voice-agent")
                .to_string(),
            stt_server,
            tts_server,
        }
    }
}

/// The one live-call handler every voice agent uses; `--live-config` selects
/// the backend.
pub struct VoiceAgentHandler {
    factories: HashMap<String, Arc<dyn VoiceBackendFactory>>,
}

impl Default for VoiceAgentHandler {
    fn default() -> Self {
        Self::new()
    }
}

impl VoiceAgentHandler {
    pub fn new() -> Self {
        Self {
            factories: HashMap::new(),
        }
    }

    /// Register a backend. The runner calls this once per engine it links.
    pub fn with(mut self, factory: Arc<dyn VoiceBackendFactory>) -> Self {
        self.factories.insert(factory.kind().to_string(), factory);
        self
    }
}

impl LiveCallHandler for VoiceAgentHandler {
    fn capabilities(&self) -> &'static [&'static str] {
        &[AUDIO_PUBLISH]
    }

    fn handle(&self, ctx: LiveCallContext) -> LiveCallFuture {
        // In-call caller text from an app running STT on-device.
        if let Some(text) = caller_text_control(&ctx.text) {
            return Box::pin(async move {
                let sender = {
                    active_call()
                        .lock()
                        .ok()
                        .and_then(|handle| handle.as_ref().map(|handle| handle.text.clone()))
                };
                if let Some(sender) = sender {
                    let _ = sender.send(text);
                }
                Ok(true)
            });
        }
        let config = VoiceAgentConfig::from_params(&ctx.params);
        let factory = self.factories.get(&config.backend).cloned();
        Box::pin(async move { handle_call(ctx, config, factory).await })
    }
}

/// Parse a caller-text control: `IDFON-LIVE/1\naction=text\ntext_b64=<base64>`.
fn caller_text_control(text: &str) -> Option<String> {
    let body = text.strip_prefix("IDFON-LIVE/1\n")?;
    let mut action = None;
    let mut payload = None;
    for line in body.lines() {
        if let Some(value) = line.strip_prefix("action=") {
            action = Some(value);
        }
        if let Some(value) = line.strip_prefix("text_b64=") {
            payload = Some(value);
        }
    }
    if action != Some("text") {
        return None;
    }
    use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
    String::from_utf8(BASE64.decode(payload?).ok()?).ok()
}

async fn handle_call(
    ctx: LiveCallContext,
    config: VoiceAgentConfig,
    factory: Option<Arc<dyn VoiceBackendFactory>>,
) -> Result<bool> {
    // Voice is 1:1 only.
    if ctx.is_room() {
        return Ok(false);
    }
    let Some(invite) = parse_invite(&ctx.text) else {
        return Ok(false);
    };
    if invite.is_stop {
        stop_active_call(&format!("peer {} hung up", ctx.sender_peer_id));
        return Ok(true);
    }
    if !invite.is_start {
        return Ok(true);
    }
    let Some(factory) = factory else {
        eprintln!("[voice-agent] unknown backend '{}'; falling through to text", config.backend);
        return Ok(false);
    };
    // A backend that cannot start (e.g. no provider key) declines the call, and
    // the control becomes a text turn.
    let mut backend = match factory.create(&ctx.params) {
        Ok(backend) => backend,
        Err(error) => {
            eprintln!("[voice-agent] backend '{}' unavailable: {error}", config.backend);
            return Ok(false);
        }
    };
    let profile = parse_audio_profile(invite.audio_codec.as_deref(), invite.audio_sample_rate)?;
    let ticket = invite
        .ticket
        .ok_or_else(|| anyhow!("live call start is missing its media ticket"))?;
    let endpoint_id = ctx
        .sender_endpoint_id
        .parse::<EndpointId>()
        .map_err(|error| anyhow!("invalid caller endpoint id: {error}"))?;
    let caller_addr = match invite.return_addr {
        Some(address) if address.id == endpoint_id => address,
        Some(_) => anyhow::bail!("caller return address does not match sender endpoint"),
        None => EndpointAddr::new(endpoint_id),
    };

    stop_active_call("replaced by a newer call");
    let session = CallSession::start(
        &caller_addr,
        &ctx.sender_peer_id,
        &ctx.holder_endpoint_id,
        &ctx.transport,
        &ctx.key,
        profile,
        &config.broadcast,
    )
    .await
    .context("start voice-agent call")?;
    let stop = Arc::clone(&session.stop);
    // Caller audio is only needed when the holder runs STT; otherwise the
    // caller runs it on-device and sends text over a live control, so we keep
    // an idle channel (with its sender alive) instead of subscribing.
    let (caller, caller_keepalive) = if config.stt_server {
        (subscribe_caller(ticket, profile, Arc::clone(&stop)).await?, None)
    } else {
        let (tx, rx) = mpsc::channel(1);
        (rx, Some(tx))
    };
    let (text_tx, caller_text) = mpsc::unbounded_channel::<String>();
    *active_call().lock().expect("call mutex poisoned") = Some(CallHandle {
        stop: Arc::clone(&stop),
        text: text_tx,
        _caller_keepalive: caller_keepalive,
    });
    let audio = session.audio.clone();
    let bridge = TurnBridge::new(
        ctx.sender_peer_id.clone(),
        ctx.sender_endpoint_id.clone(),
        config.source.clone(),
        Arc::clone(&ctx.targets),
        ctx.out_tx.clone(),
    );
    // Register this call as the delta sink for the caller so agent-output
    // deltas reach its TTS (F11). Replaced if a newer call for the peer starts.
    let (delta_tx, deltas) = mpsc::unbounded_channel();
    eve_idfon::deltas::register(&ctx.sender_peer_id, delta_tx);
    let call_peer = ctx.sender_peer_id.clone();
    let media = VoiceMedia {
        caller,
        caller_text,
        deltas,
        audio,
        stop,
        profile,
        bridge,
        platform: CallPlatform {
            transport: Arc::clone(&ctx.transport),
            key: ctx.key.clone(),
            holder_endpoint_id: ctx.holder_endpoint_id.clone(),
            caller_addr: caller_addr.clone(),
            caller_peer_id: ctx.sender_peer_id.clone(),
            targets: Arc::clone(&ctx.targets),
            out_tx: ctx.out_tx.clone(),
        },
    };
    eprintln!(
        "[voice-agent] call started backend={} peer={}",
        backend.name(),
        ctx.sender_peer_id
    );
    tokio::spawn(async move {
        if let Err(error) = backend.run(media).await {
            eprintln!("[voice-agent] backend '{}' failed: {error:#}", backend.name());
        }
        session.shutdown().await;
        eve_idfon::deltas::unregister(&call_peer);
        eprintln!("[voice-agent] call ended");
    });
    Ok(true)
}

struct CallHandle {
    stop: Arc<AtomicBool>,
    /// Caller-text sink for `voice_route.stt = client`.
    text: mpsc::UnboundedSender<String>,
    /// Held so the idle caller channel stays open when the holder doesn't STT.
    _caller_keepalive: Option<mpsc::Sender<Vec<i16>>>,
}

static ACTIVE_CALL: OnceLock<Mutex<Option<CallHandle>>> = OnceLock::new();

fn active_call() -> &'static Mutex<Option<CallHandle>> {
    ACTIVE_CALL.get_or_init(|| Mutex::new(None))
}

fn stop_active_call(reason: &str) {
    if let Some(handle) = active_call().lock().expect("call mutex poisoned").take() {
        handle.stop.store(true, Ordering::Relaxed);
        eprintln!("[voice-agent] call stopped: {reason}");
    }
}

/// Drop trailing `IDFON-*/1` envelope blocks before speaking.
pub fn strip_envelopes(text: &str) -> String {
    let mut out = String::new();
    for line in text.lines() {
        let trimmed = line.trim_end();
        if trimmed.starts_with("IDFON-") && trimmed.ends_with("/1") {
            break;
        }
        out.push_str(line);
        out.push('\n');
    }
    out.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_defaults_and_overrides() {
        let default = VoiceAgentConfig::from_params(&serde_json::Value::Null);
        assert_eq!(default.backend, "cascade");
        let overridden = VoiceAgentConfig::from_params(&serde_json::json!({
            "engine": { "kind": "gpt-live" },
            "broadcast": "b",
            "source": "s",
        }));
        assert_eq!(overridden.backend, "gpt-live");
        assert_eq!(overridden.broadcast, "b");
        assert_eq!(overridden.source, "s");
    }

    #[test]
    fn strips_trailing_envelope() {
        assert_eq!(
            strip_envelopes("Sure, here you go.\nIDFON-INVITE/1\nname=x"),
            "Sure, here you go."
        );
        assert_eq!(strip_envelopes("plain reply"), "plain reply");
    }

    #[test]
    fn parses_caller_text_control() {
        assert_eq!(
            caller_text_control("IDFON-LIVE/1\naction=text\ntext_b64=aGVsbG8=").as_deref(),
            Some("hello")
        );
        // Non-text controls and malformed payloads are ignored.
        assert_eq!(caller_text_control("IDFON-LIVE/1\naction=start"), None);
        assert_eq!(caller_text_control("IDFON-LIVE/1\naction=text"), None);
        assert_eq!(caller_text_control("plain"), None);
    }

    #[test]
    fn hybrid_ownership_from_voice_route() {
        let hybrid = VoiceAgentConfig::from_params(&serde_json::json!({
            "voice_route": { "mode": "server-cascade", "stt": "client", "tts": "server" }
        }));
        assert!(!hybrid.stt_server);
        assert!(hybrid.tts_server);
        // Absent overrides: the holder does both halves.
        let both = VoiceAgentConfig::from_params(&serde_json::json!({
            "voice_route": { "mode": "server-cascade" }
        }));
        assert!(both.stt_server && both.tts_server);
    }
}
