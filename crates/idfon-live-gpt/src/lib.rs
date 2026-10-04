//! GPT-Live live-call handler: one full-duplex voice backend.
//!
//! GPT-Live-1 is one of several models/engines a **voice agent** can run
//! (`docs/voice-agent.md`); the server-side cascade is another. This crate is
//! simply the backend that hosts a GPT-Live session over the shared live-media
//! transport, advertised as the `native-duplex` route. No special status:
//! add or swap backends behind the same seam as needed.
//!
//! This is an **agent-side** opt-in for the platform's live-call seam
//! (`eve_idfon::live`). It answers a 1:1 idfon call with an OpenAI
//! `gpt-live-1` session and is registered against `live.audio.publish`; the
//! generic holder knows none of the vendor values below.
//!
//! Flow (the ticket flow the Apple apps already use — publish `idfon-live-*`,
//! subscribe the peer's ticket — not the daemon harness's session-scoped
//! `calls/<id>` path):
//!
//! 1. The caller publishes its mic and sends an `IDFON-LIVE/1 action=start
//!    ticket=<caller ticket> return_addr=<base64 EndpointAddr>` message. The
//!    holder dispatches it (before Eve sees it) to this handler.
//! 2. The handler opens one GPT-Live WS session, subscribes the caller's audio
//!    (decode to s16 24 kHz mono → `session.input_audio.append`), and publishes
//!    its own side (`session.output_audio.delta` → push queue → Live broadcast)
//!    using the codec/rate advertised in the caller's invite.
//! 3. The handler sends the return-leg invite carrying its own ticket, so the
//!    caller subscribes and the call goes two-way (`.calling` → `.inCall`).
//! 4. `action=stop` text, a WS close, or a dead subscriber tears the call
//!    down. One call at a time: a new invite replaces the old one.
//!
//! Without the configured provider key in the holder environment calls are not
//! intercepted at all — invite texts fall through to Eve, whose instructions
//! decline them.

use std::{collections::VecDeque, sync::{ 
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex, OnceLock,
}, time::{Duration, Instant}};

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use ed25519_dalek::SigningKey;
use eve_idfon::{
    live::{LiveCallContext, LiveCallFuture, LiveCallHandler, AUDIO_PUBLISH},
    records, IpcFrame, ReplyTarget,
};
use futures_util::{SinkExt, StreamExt};
use idfon_core::transport::{IrohTransport, MessageTransport};
use idfon_live_media::{
    parse_audio_profile, parse_invite, rand_suffix, AudioProfile, CallSession,
};
use idfon_protocol::{CallSpeaker, CallTranscript, MessageContent};
use iroh::{EndpointAddr, EndpointId};
use iroh_live::ticket::LiveTicket;
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_websockets::{ClientBuilder, Message};

/// Agent/channel configuration for the GPT-Live handler. Every value the
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
    /// Build from the opaque channel metadata handed to the handler.
    pub fn from_params(params: &Value) -> Self {
        serde_json::from_value(params.clone()).unwrap_or_default()
    }
}

/// The live-call handler registered against `live.audio.publish`.
#[derive(Default)]
pub struct GptLiveHandler;

impl LiveCallHandler for GptLiveHandler {
    fn capabilities(&self) -> &'static [&'static str] {
        &[AUDIO_PUBLISH]
    }

    fn handle(&self, ctx: LiveCallContext) -> LiveCallFuture {
        Box::pin(async move { handle_live_text(ctx).await })
    }
}

const STARTUP_TIMEOUT: Duration = Duration::from_secs(20);
const SESSION_CLOSE_TIMEOUT: Duration = Duration::from_secs(15);
// Transcript streaming: a new turn starts on a speaker switch or a pause this
// long; snapshots are sent at most this often so a turn is a few messages, not
// one per delta.
const TRANSCRIPT_TURN_GAP: Duration = Duration::from_millis(1200);
const TRANSCRIPT_SNAPSHOT: Duration = Duration::from_millis(400);
const TRANSCRIPT_MAX_CHARS: usize = 2000;

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

    fn push(&mut self, speaker: CallSpeaker, delta: &str, out: &mpsc::UnboundedSender<CallTranscript>) {
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
            CallSpeaker::Caller => CallTranscript::caller(&self.call_id, &self.turn_id, &self.text, r#final),
            CallSpeaker::Agent => CallTranscript::agent(&self.call_id, &self.turn_id, &self.text, r#final),
        };
        let _ = out.send(transcript);
        self.last_snapshot = Some(Instant::now());
        if r#final {
            self.text.clear();
        }
    }
}

struct CallHandle {
    stop: Arc<AtomicBool>,
}

/// The one active call (`None` = idle). A new invite stops the old call.
static ACTIVE_CALL: OnceLock<Mutex<Option<CallHandle>>> = OnceLock::new();

fn active_call() -> &'static Mutex<Option<CallHandle>> {
    ACTIVE_CALL.get_or_init(|| Mutex::new(None))
}

fn stop_active_call(reason: &str) {
    if let Some(handle) = active_call().lock().expect("call mutex poisoned").take() {
        handle.stop.store(true, Ordering::Relaxed);
        eprintln!("[eve-idfon] call stopped: {reason}");
    }
}

/// Intercepts call-control texts. Returns `true` when the message was consumed
/// (a call start/stop this handler owns) and must not reach Eve.
pub async fn handle_live_text(ctx: LiveCallContext) -> Result<bool> {
    // Voice is 1:1 only. A room (>= 2 distinct senders) never opens a voice
    // session; the control falls through and is handled as text content.
    if ctx.is_room() {
        eprintln!(
            "[eve-idfon] room-addressed live control rejected (voice is 1:1) peer={} conversation={:?}",
            ctx.sender_peer_id, ctx.conversation
        );
        return Ok(false);
    }
    let config = GptLiveConfig::from_params(&ctx.params);
    let Some(invite) = parse_invite(&ctx.text) else {
        return Ok(false);
    };
    if invite.is_stop {
        stop_active_call(&format!("peer {} hung up", ctx.sender_peer_id));
        return Ok(true);
    }
    if !invite.is_start {
        return Ok(true); // unknown action: consume rather than confuse the agent
    }
    // Without the configured provider key the agent (text/memo path) handles
    // the turn; its instructions decline the call politely.
    let api_key = match std::env::var(&config.api_key_env) {
        Ok(key) if !key.is_empty() => key,
        _ => return Ok(false),
    };
    let profile = parse_audio_profile(invite.audio_codec.as_deref(), invite.audio_sample_rate)?;
    let ticket = invite
        .ticket
        .ok_or_else(|| anyhow!("live call start is missing its media ticket"))?;
    let endpoint_id = ctx
        .sender_endpoint_id
        .parse::<EndpointId>()
        .map_err(|error| anyhow!("invalid caller endpoint id: {error}"))?;
    eprintln!(
        "[eve-idfon] call invite peer={} explicit_return_addr={} response_codec={} response_rate={}",
        ctx.sender_peer_id,
        invite.return_addr.is_some(),
        profile.codec,
        profile.sample_rate
    );
    let caller_addr = match invite.return_addr {
        Some(address) if address.id == endpoint_id => address,
        Some(_) => {
            anyhow::bail!("caller return address does not match sender endpoint");
        }
        None => EndpointAddr::new(endpoint_id), // legacy callers rely on discovery
    };
    // Delegated deep work from the live session runs as a normal Eve turn: the
    // consumer registers a reply target for each request so the agent's reply
    // (text + any `IDFON-ARTIFACT/1` envelope) is routed to the caller, while
    // the stripped text also reaches the live session's commentary.
    let (delegation_tx, mut delegation_rx) = mpsc::unbounded_channel::<Delegation>();
    {
        let peer_id = ctx.sender_peer_id.clone();
        let endpoint_id = ctx.sender_endpoint_id.clone();
        let targets = Arc::clone(&ctx.targets);
        let out_tx = ctx.out_tx.clone();
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
    if let Err(error) = start_call(
        ticket,
        caller_addr,
        ctx.sender_peer_id.clone(),
        &ctx.holder_endpoint_id,
        Arc::clone(&ctx.transport),
        ctx.key.clone(),
        api_key,
        profile,
        config,
        delegation_tx,
    )
    .await
    {
        eprintln!("[eve-idfon] call failed: {error:#}");
        stop_active_call("start failed");
        return Err(error);
    }
    Ok(true)
}

/// Accepts a call and runs it on a background task. Sends the return-leg
/// invite (own ticket) so the caller subscribes. Returns once the call is up
/// (or failed); the session task keeps running until the call ends.
async fn start_call(
    caller_ticket: LiveTicket,
    caller_addr: EndpointAddr,
    caller_peer_id: String,
    holder_endpoint_id: &str,
    transport: Arc<IrohTransport>,
    key: SigningKey,
    api_key: String,
    profile: AudioProfile,
    config: GptLiveConfig,
    delegation_tx: mpsc::UnboundedSender<Delegation>,
) -> Result<()> {
    stop_active_call("replaced by a newer call");
    // Publish the return leg and send the return-leg invite (idfon-live-media).
    let session = CallSession::start(
        &caller_addr,
        &caller_peer_id,
        holder_endpoint_id,
        &transport,
        &key,
        profile,
        &config.broadcast,
    )
    .await
    .context("start live media session")?;
    let stop = Arc::clone(&session.stop);
    *active_call().lock().expect("call mutex poisoned") = Some(CallHandle {
        stop: Arc::clone(&stop),
    });
    eprintln!("[eve-idfon] call accepted from {caller_peer_id}, return leg sent");

    // Drive the GPT-Live session + caller audio until the call ends. The task
    // owns the media session (its endpoint serves the return leg) and shuts it
    // down when the call ends — dropping it early kills subscribers.
    let holder_endpoint_id = holder_endpoint_id.to_string();
    let task = tokio::spawn(async move {
        let result = run_session(
            &session,
            caller_ticket,
            api_key,
            profile,
            transport,
            key,
            holder_endpoint_id,
            caller_addr,
            caller_peer_id,
            config,
            delegation_tx,
        )
        .await;
        stop.store(true, Ordering::Relaxed);
        session.shutdown().await;
        if let Err(error) = &result {
            eprintln!("[eve-idfon] live session failed: {error:#}");
        }
        result
    });
    tokio::time::timeout(STARTUP_TIMEOUT, async {
        loop {
            if task.is_finished() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .ok();
    if task.is_finished() {
        match task.await {
            Err(join) => Err(anyhow!("call task died: {join}")),
            Ok(Err(error)) => Err(error),
            Ok(Ok(())) => Ok(()),
        }
    } else {
        Ok(()) // call is up and running
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idfon_live_media::{CallerPacer, CHUNK_SAMPLES, MAX_INPUT_BUFFER};
    use moq_audio::encode::Codec as AudioCodec;

    #[test]
    fn config_defaults_and_channel_overrides() {
        let defaults = GptLiveConfig::from_params(&serde_json::Value::Null);
        assert_eq!(defaults.model, "openai/gpt-live-1");
        assert_eq!(defaults.api_key_env, "AI_GATEWAY_API_KEY");
        assert_eq!(defaults.broadcast, "idfon-live-agent");
        let overridden = GptLiveConfig::from_params(&json!({
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
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../agents/live-voice/live.json");
        let raw = std::fs::read_to_string(path).expect("read live.json");
        let config: GptLiveConfig = serde_json::from_str(&raw).expect("parse live.json");
        assert_eq!(config.model, "openai/gpt-live-1");
        assert_eq!(config.broadcast, "idfon-live-agent");
        assert!(!config.instructions.is_empty());
    }

    /// Simulates pump_caller_audio's steady loop: one 20 ms tick consumes, one
    /// 480-sample frame arrives. Returns total late-dropped samples.
    fn simulate(pacer: &mut CallerPacer, iterations: usize, frame_lag_us: u128) -> u64 {
        let mut late_total = 0u64;
        let mut pts = 0i128;
        let mut queued_after_tick = 0usize;
        for i in 0..iterations {
            let mut pcm = [0i16; CHUNK_SAMPLES];
            let (_, _) = pacer.tick(&mut pcm);
            // Frame arrives after the tick consumed, trailing by frame_lag_us.
            pts += (CHUNK_SAMPLES as i128) * 1_000_000 / 24_000;
            let data = vec![100i16 + i as i16; CHUNK_SAMPLES];
            late_total += pacer.accept_frame(pts - frame_lag_us as i128, &data);
            queued_after_tick = pacer.input.len();
        }
        let _ = queued_after_tick;
        late_total
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

    /// Regression: a starved tick (queue empty, cursor runs one frame ahead of
    /// pts) must not permanently mute the caller. Pre-fix, every subsequent
    /// frame was late-dropped forever (seen live: mic dead from ~19.6s).
    #[test]
    fn frames_trailing_ticks_are_accepted_not_locked_out() {
        let mut pacer = CallerPacer::new();
        // Two starved ticks grow the deficit to 960 (pre-lock trigger).
        pacer.tick(&mut [0i16; CHUNK_SAMPLES]);
        pacer.tick(&mut [0i16; CHUNK_SAMPLES]);
        // Frames now trail ticks by 5 ms every interval: was a permanent lock.
        let late = simulate(&mut pacer, 50, 5_000);
        assert_eq!(late, 0, "late-dropped frames after realign recovery");
        // The caller's audio is in the queue, not silence.
        assert!(pacer.input.len() > 0);
    }

    /// The 18.37s gap+burst pattern: three starved ticks, then three frames at
    /// once. All must be accepted (the old code late-dropped the burst and,
    /// depending on subsequent timing, could wedge into the lock).
    #[test]
    fn gap_then_burst_accepts_all_frames() {
        let mut pacer = CallerPacer::new();
        for _ in 0..3 {
            pacer.tick(&mut [0i16; CHUNK_SAMPLES]);
        }
        for i in 0..3 {
            let pts = (i + 1) as i128 * 20_000;
            assert_eq!(pacer.accept_frame(pts, &[7i16; CHUNK_SAMPLES]), 0);
        }
        assert_eq!(pacer.input.len(), 3 * CHUNK_SAMPLES);
        assert_eq!(pacer.dropped_samples, 0);
    }

    /// A forward pts jump (timestamp reset upward) fills capped silence and
    /// counts the excess as dropped instead of allocating unbounded memory.
    #[test]
    fn forward_pts_jump_fill_is_capped() {
        let mut pacer = CallerPacer::new();
        // Establish a timeline first: the first frame defines the origin.
        pacer.accept_frame(0, &[1i16; CHUNK_SAMPLES]);
        pacer.accept_frame(20_000, &[1i16; CHUNK_SAMPLES]);
        assert_eq!(pacer.input.len(), 2 * CHUNK_SAMPLES);
        // Jump 60 s forward.
        let late = pacer.accept_frame(60_000_000, &[9i16; CHUNK_SAMPLES]);
        assert_eq!(late, 0);
        assert_eq!(pacer.input.len(), MAX_INPUT_BUFFER);
        // target jumped to 60 s worth of samples; everything beyond the capped
        // fill is accounted as dropped, and the queue stays bounded.
        let jump_samples = 60_000u64 * 24;
        assert!(pacer.dropped_samples >= jump_samples - MAX_INPUT_BUFFER as u64);
    }

    /// A backward pts jump clamps target to 0 and late-drops while the queue
    /// has backlog, but must recover via realign instead of locking forever.
    #[test]
    fn backward_pts_jump_recovers_via_realign() {
        let mut pacer = CallerPacer::new();
        // Establish a healthy timeline.
        for i in 0..5 {
            pacer.accept_frame(i * 20_000, &[1i16; CHUNK_SAMPLES]);
            pacer.tick(&mut [0i16; CHUNK_SAMPLES]);
        }
        // Jump pts backwards 5 s, then keep streaming monotonically.
        let mut late_after_jump = Vec::new();
        for i in 0..100 {
            let pts = -5_000_000 + (i as i128) * 20_000;
            late_after_jump.push(pacer.accept_frame(pts, &[2i16; CHUNK_SAMPLES]));
            pacer.tick(&mut [0i16; CHUNK_SAMPLES]);
        }
        assert!(late_after_jump.iter().all(|&late| late == 0));
        assert_eq!(pacer.dropped_samples, 0);
    }

    /// A burst larger than the buffer trims from the front and bounds memory.
    #[test]
    fn overflow_trims_oldest_samples() {
        let mut pacer = CallerPacer::new();
        let big = vec![3i16; MAX_INPUT_BUFFER + 960];
        let pts = (MAX_INPUT_BUFFER + 960) as i128 * 1_000_000 / 24_000;
        let late = pacer.accept_frame(pts, &big);
        assert_eq!(late, 0);
        assert_eq!(pacer.input.len(), MAX_INPUT_BUFFER);
        assert_eq!(pacer.dropped_samples, 960);
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
        let address = EndpointAddr::new(id);
        let encoded = BASE64.encode(serde_json::to_vec(&address).unwrap());
        let invite = parse_invite(&format!(
            "IDFON-LIVE/1\naction=start\nticket=ticket\nreturn_addr={encoded}"
        ))
        .unwrap();
        assert_eq!(invite.return_addr.unwrap().id, id);
    }

    #[test]
    fn caller_profile_is_mirrored_and_legacy_invites_default_to_opus() {
        let invite = parse_invite(
            "IDFON-LIVE/1\naction=start\nticket=t\naudio_codec=pcm\naudio_sample_rate=24000",
        )
        .unwrap();
        assert_eq!(
            parse_audio_profile(invite.audio_codec.as_deref(), invite.audio_sample_rate).unwrap(),
            AudioProfile {
                codec: AudioCodec::Pcm,
                sample_rate: 24_000
            },
        );
        assert_eq!(
            parse_audio_profile(None, None).unwrap(),
            AudioProfile {
                codec: AudioCodec::Opus,
                sample_rate: 48_000
            },
        );
        assert!(parse_audio_profile(Some("pcm"), Some(48_000)).is_err());
    }

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

/// The GPT-Live session: caller audio in, spoken reply out, until hangup.
async fn run_session(
    session: &CallSession,
    caller_ticket: LiveTicket,
    api_key: String,
    profile: AudioProfile,
    transport: Arc<IrohTransport>,
    key: SigningKey,
    holder_endpoint_id: String,
    caller_addr: EndpointAddr,
    caller_peer_id: String,
    config: GptLiveConfig,
    delegation_tx: mpsc::UnboundedSender<Delegation>,
) -> Result<()> {
    let stop = Arc::clone(&session.stop);
    let audio = session.audio.clone();
    let ws = connect_live(&api_key, &config).await?;
    let (mut ws_tx, mut ws_rx) = ws.split();
    eprintln!("[eve-idfon] GPT-Live session ready peer={caller_peer_id}");

    let call_started = Instant::now();
    let turn_count = Arc::new(AtomicU64::new(0));
    let call_id = rand_suffix();
    // Delegated replies arrive as `(delegation_id, spoken_text)` and are fed to
    // GPT-Live as commentary by the task that owns `ws_tx`.
    let (commentary_tx, commentary_rx) = mpsc::unbounded_channel::<(String, String)>();
    // Transcript snapshots are signed and sent off the reader loop so a slow
    // send cannot stall audio; one task preserves snapshot order. Finals are
    // also written to the durable voice-record buffer keyed by the caller
    // (P0: recording never triggers an Eve turn).
    let (transcript_tx, mut transcript_rx) = mpsc::unbounded_channel::<CallTranscript>();
    // Spoken copies of delegated replies: GPT-Live reads them back as output
    // transcripts, which must not be recorded as a second copy of a reply the
    // Eve agent already wrote into its own history.
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
                        eprintln!("[eve-idfon] call transcript sign failed: {error}");
                        continue;
                    }
                };
                if let Err(error) = transport.send(&caller_addr, &envelope).await {
                    eprintln!("[eve-idfon] call transcript send failed: {error}");
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
                    eprintln!("[eve-idfon] GPT-Live websocket read failed: {error}");
                    break;
                }
            };
            let Some(text) = message.as_text() else {
                continue;
            };
            let Ok(event) = serde_json::from_str::<serde_json::Value>(text) else {
                eprintln!("[eve-idfon] ignored non-JSON GPT-Live event");
                continue;
            };
            match event["type"].as_str().unwrap_or_default() {
                "session.input_transcript.delta" => {
                    let delta = event["delta"].as_str().unwrap_or_default();
                    input_text_chars += delta.len();
                    stream.push(CallSpeaker::Caller, delta, &transcript_tx);
                    eprintln!("[eve-idfon] GPT-Live input transcript chars={input_text_chars}");
                }
                "session.output_transcript.delta" => {
                    let delta = event["delta"].as_str().unwrap_or_default();
                    output_text_chars += delta.len();
                    stream.push(CallSpeaker::Agent, delta, &transcript_tx);
                    eprintln!("[eve-idfon] GPT-Live output transcript chars={output_text_chars}");
                }
                "session.delegation.created" => {
                    let delegation_id = event["delegation"]["id"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string();
                    if !delegation_id.is_empty() {
                        let said = stream.latest_caller_text();
                        let request = config.delegation_request.replace("{said}", &said);
                        let _ = delegation_tx.send(Delegation {
                            delegation_id,
                            request,
                            reply: reader_commentary.clone(),
                        });
                        eprintln!("[eve-idfon] live delegation dispatched");
                    }
                }
                "session.output_audio.delta" => {
                    if let Some(delta) = event["delta"].as_str().and_then(|d| BASE64.decode(d).ok())
                    {
                        output_chunks += 1;
                        output_bytes += delta.len();
                        reader_audio.push_bytes(&delta);
                        if output_chunks == 1 || output_chunks % 50 == 0 {
                            eprintln!("[eve-idfon] GPT-Live audio out chunks={output_chunks} bytes={output_bytes}");
                        }
                    }
                }
                "session.closed" => {
                    finalized = true;
                    reader_finalized.store(true, Ordering::Relaxed);
                    eprintln!(
                        "[eve-idfon] GPT-Live session closed usage={} reason={}",
                        event["usage"],
                        event["reason"].as_str().unwrap_or("(none)"),
                    );
                    break;
                }
                "error" => {
                    eprintln!("[eve-idfon] GPT-Live error: {}", event["error"]);
                    break;
                }
                _ => {}
            }
        }
        stream.flush(true, &transcript_tx);
        reader_stop.store(true, Ordering::Relaxed);
        eprintln!(
            "[eve-idfon] GPT-Live reader done finalized={finalized} audio_chunks={output_chunks} audio_bytes={output_bytes} input_text_chars={input_text_chars} output_text_chars={output_text_chars}"
        );
        finalized
    });

    // Caller audio → WS; on hangup, cancel the pump and close GPT-Live cleanly.
    let pacer_stop = Arc::clone(&stop);
    let pacer_finalized = Arc::clone(&session_finalized);
    let mut pacer = tokio::spawn(async move {
        let pump_stop = Arc::clone(&pacer_stop);
        let result = tokio::select! {
            _ = async {
                while !pacer_stop.load(Ordering::Relaxed) {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            } => Ok(()),
            result = pump_caller_audio(caller_ticket, &mut ws_tx, pump_stop, profile, config.reply_max_seconds, commentary_rx, Arc::clone(&delegated_spoken)) => result,
        };
        if let Err(error) = result {
            eprintln!("[eve-idfon] caller audio ended: {error:#}");
        }
        if !pacer_finalized.load(Ordering::Relaxed) {
            let close = Message::text(json!({"type": "session.close"}).to_string());
            match tokio::time::timeout(Duration::from_secs(2), ws_tx.send(close)).await {
                Ok(Ok(())) => eprintln!("[eve-idfon] GPT-Live session.close sent"),
                Ok(Err(error)) => {
                    eprintln!("[eve-idfon] GPT-Live session.close failed: {error}")
                }
                Err(_) => eprintln!("[eve-idfon] GPT-Live session.close timed out"),
            }
        }
        pacer_stop.store(true, Ordering::Relaxed);
    });

    let finalized = tokio::select! {
        result = &mut reader => {
            stop.store(true, Ordering::Relaxed);
            if let Err(error) = tokio::time::timeout(Duration::from_secs(2), &mut pacer).await {
                eprintln!("[eve-idfon] audio pump cleanup timed out: {error}");
                pacer.abort();
            }
            match result {
                Ok(finalized) => finalized,
                Err(error) => {
                    eprintln!("[eve-idfon] GPT-Live reader task failed: {error}");
                    false
                }
            }
        }
        result = &mut pacer => {
            if let Err(error) = result {
                eprintln!("[eve-idfon] caller audio task failed: {error}");
            }
            match tokio::time::timeout(SESSION_CLOSE_TIMEOUT, &mut reader).await {
                Ok(Ok(finalized)) => finalized,
                Ok(Err(error)) => {
                    eprintln!("[eve-idfon] GPT-Live reader task failed: {error}");
                    false
                }
                Err(_) => {
                    eprintln!("[eve-idfon] GPT-Live close timed out; dropping websocket reader");
                    reader.abort();
                    let _ = reader.await;
                    false
                }
            }
        }
    };
    // Let the transcript task finish the queue (its sender lives in the reader
    // task, which has ended) so the hangup summary is recorded last.
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
        eprintln!("[eve-idfon] GPT-Live finalization unconfirmed");
    }
    stop_active_call("session ended");
    Ok(())
}

/// Opens the live session for one call.
async fn connect_live(
    api_key: &str,
    config: &GptLiveConfig,
) -> Result<
    tokio_websockets::WebSocketStream<tokio_websockets::MaybeTlsStream<tokio::net::TcpStream>>,
> {
    eprintln!("[eve-idfon] connecting to live session");
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
    eprintln!("[eve-idfon] live session.started");
    Ok(ws)
}

/// Streams the caller's mic broadcast to GPT-Live: `idfon-live-media` owns the
/// subscribe/decode/pacing, this forwards the 20 ms frames and commentary.
async fn pump_caller_audio<S>(
    ticket: LiveTicket,
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
    let mut frames = idfon_live_media::subscribe_caller(ticket, profile, Arc::clone(&stop)).await?;
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
                    eprintln!("[eve-idfon] caller appends={chunks}");
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
    }
    Ok(())
}
