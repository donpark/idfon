//! Cascade live-call handler: the voice agent's ears and mouth.
//!
//! A voice agent is an idfon peer (see `docs/voice-agent.md`). Its holder
//! registers this handler, which shares a live MoQ session with the caller and
//! runs the **cascade**: caller audio → STT → a normal agent turn → TTS →
//! return audio. The text target is the voice agent's own Eve agent by default,
//! so the handler stays generic and wrapping is agent logic.
//!
//! Engine: [`idfon_voice::gateway::GatewayVoiceEngine`] (cloud, AI Gateway) is
//! the demo provider; a local engine can replace it behind the same
//! `VoiceEngine` seam.

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex, OnceLock,
};

use anyhow::{anyhow, Context, Result};
use eve_idfon::{
    live::{LiveCallContext, LiveCallFuture, LiveCallHandler, AUDIO_PUBLISH},
    records, IpcFrame, ReplyTarget,
};
use idfon_live_media::{
    parse_audio_profile, parse_invite, rand_suffix, subscribe_caller, AudioProfile, CallSession,
    LiveTicket,
};
use idfon_voice::{
    gateway::GatewayVoiceEngine, normalize_for_speech, AudioFormat, EndpointEvent, VoiceEngine,
};
use iroh::{EndpointAddr, EndpointId};
use serde_json::Value;
use tokio::sync::mpsc;

/// Handler configuration read from the live config (all optional).
#[derive(Debug, Clone)]
struct CascadeConfig {
    /// MoQ broadcast name for the return leg.
    broadcast: String,
    /// Provenance tag on injected turns (distinguishes voice-originated text).
    source: String,
}

impl CascadeConfig {
    fn from_params(params: &Value) -> Self {
        Self {
            broadcast: params
                .get("broadcast")
                .and_then(|value| value.as_str())
                .unwrap_or("idfon-cascade-agent")
                .to_string(),
            source: params
                .get("source")
                .and_then(|value| value.as_str())
                .unwrap_or("cascade-live")
                .to_string(),
        }
    }
}

/// The cascade live-call handler.
pub struct CascadeLiveHandler;

impl LiveCallHandler for CascadeLiveHandler {
    fn capabilities(&self) -> &'static [&'static str] {
        &[AUDIO_PUBLISH]
    }

    fn handle(&self, ctx: LiveCallContext) -> LiveCallFuture {
        Box::pin(async move { handle_live(ctx).await })
    }
}

async fn handle_live(ctx: LiveCallContext) -> Result<bool> {
    // Voice is 1:1 only.
    if ctx.is_room() {
        return Ok(false);
    }
    let config = CascadeConfig::from_params(&ctx.params);
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
    // Without a provider key there is no engine: fall through to a text turn.
    let engine = match GatewayVoiceEngine::from_env() {
        Ok(engine) => engine,
        Err(error) => {
            eprintln!("[cascade] no voice engine ({error}); falling through to text");
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
    .context("start cascade call")?;
    eprintln!("[cascade] call started for {}", ctx.sender_peer_id);

    let stop = Arc::clone(&session.stop);
    *active_call().lock().expect("call mutex poisoned") = Some(CallHandle {
        stop: Arc::clone(&stop),
    });

    let peer_id = ctx.sender_peer_id.clone();
    let endpoint_id = ctx.sender_endpoint_id.clone();
    let targets = Arc::clone(&ctx.targets);
    let out_tx = ctx.out_tx.clone();
    tokio::spawn(async move {
        if let Err(error) = run_cascade(
            session,
            engine,
            ticket,
            profile,
            stop,
            peer_id,
            endpoint_id,
            targets,
            out_tx,
            config.source,
        )
        .await
        {
            eprintln!("[cascade] call failed: {error:#}");
        }
    });
    Ok(true)
}

#[allow(clippy::too_many_arguments)]
async fn run_cascade(
    session: CallSession,
    engine: GatewayVoiceEngine,
    ticket: LiveTicket,
    profile: AudioProfile,
    stop: Arc<AtomicBool>,
    peer_id: String,
    endpoint_id: String,
    targets: eve_idfon::Targets,
    out_tx: mpsc::Sender<IpcFrame>,
    source: String,
) -> Result<()> {
    let mut frames = subscribe_caller(ticket, profile, Arc::clone(&stop)).await?;
    let format = AudioFormat::PCM_24K_MONO;
    let mut stt = engine.stt(format)?;
    let mut endpointer = engine.endpointer(format)?;
    let (commentary_tx, mut commentary_rx) = mpsc::unbounded_channel::<(String, String)>();
    let call_id = rand_suffix();
    let mut turn_seq = 0u64;

    loop {
        tokio::select! {
            item = frames.recv() => {
                let Some(pcm) = item else { break };
                let _ = stt.push(&pcm);
                if let Some(EndpointEvent::SpeechEnded) = endpointer.push(&pcm)? {
                    if let Some(text) = stt.flush()? {
                        let text = text.trim().to_string();
                        if !text.is_empty() {
                            turn_seq += 1;
                            let turn_id = format!("cascade_{call_id}_{turn_seq}");
                            records::store().append(
                                &peer_id,
                                records::VoiceRecord::transcript(&call_id, "caller", &text),
                            );
                            inject_turn(
                                &targets,
                                &out_tx,
                                &peer_id,
                                &endpoint_id,
                                &turn_id,
                                &text,
                                &source,
                                commentary_tx.clone(),
                            )
                            .await;
                        }
                    }
                }
            }
            Some((_turn_id, reply)) = commentary_rx.recv() => {
                let spoken = strip_envelopes(&reply);
                if spoken.is_empty() { continue; }
                let mut tts = engine.tts("default", format)?;
                let normalized = normalize_for_speech(&spoken);
                for chunk in tts.push_text(&normalized).unwrap_or_default() {
                    session.audio.push_samples(&chunk.samples);
                }
                for chunk in tts.finish().unwrap_or_default() {
                    session.audio.push_samples(&chunk.samples);
                }
                records::store().append(
                    &peer_id,
                    records::VoiceRecord::transcript(&call_id, "agent", &spoken),
                );
            }
            _ = tokio::time::sleep(std::time::Duration::from_millis(200)) => {
                if stop.load(Ordering::Relaxed) { break; }
            }
        }
    }
    session.shutdown().await;
    eprintln!("[cascade] call ended for {peer_id}");
    Ok(())
}

/// Inject one caller transcript as a normal agent turn and register the reply
/// route so the agent's answer comes back to us to speak.
#[allow(clippy::too_many_arguments)]
async fn inject_turn(
    targets: &eve_idfon::Targets,
    out_tx: &mpsc::Sender<IpcFrame>,
    peer_id: &str,
    endpoint_id: &str,
    turn_id: &str,
    text: &str,
    source: &str,
    commentary_tx: mpsc::UnboundedSender<(String, String)>,
) {
    targets.lock().await.insert(
        turn_id.to_string(),
        ReplyTarget {
            peer_id: peer_id.to_string(),
            endpoint_id: endpoint_id.to_string(),
            conversation: None,
            a2a_depth: None,
            live_commentary: Some((turn_id.to_string(), commentary_tx)),
        },
    );
    let frame = IpcFrame::TurnIn {
        message_id: turn_id.to_string(),
        peer_id: peer_id.to_string(),
        endpoint_id: endpoint_id.to_string(),
        idempotency_key: turn_id.to_string(),
        conversation: None,
        text: text.to_string(),
        blob_ticket: None,
        size_bytes: None,
        a2a_depth: None,
        capabilities: None,
        source: Some(source.to_string()),
    };
    let _ = out_tx.send(frame).await;
}

/// Drop trailing `IDFON-*/1` envelope blocks before speaking.
fn strip_envelopes(text: &str) -> String {
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

struct CallHandle {
    stop: Arc<AtomicBool>,
}

static ACTIVE_CALL: OnceLock<Mutex<Option<CallHandle>>> = OnceLock::new();

fn active_call() -> &'static Mutex<Option<CallHandle>> {
    ACTIVE_CALL.get_or_init(|| Mutex::new(None))
}

fn stop_active_call(reason: &str) {
    if let Some(handle) = active_call().lock().expect("call mutex poisoned").take() {
        handle.stop.store(true, Ordering::Relaxed);
        eprintln!("[cascade] call stopped: {reason}");
    }
}

// Alias keeps the long `iroh_live` ticket type readable in the signature above.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_trailing_envelope() {
        let text = "Sure, here you go.\nIDFON-INVITE/1\nname=x";
        assert_eq!(strip_envelopes(text), "Sure, here you go.");
        assert_eq!(strip_envelopes("plain reply"), "plain reply");
    }
}
