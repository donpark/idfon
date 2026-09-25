//! Live-call answering for the ai-voice-chat holder: a 1:1 idfon call whose
//! other end is a GPT-Live (`gpt-live-1`) voice session.
//!
//! Flow (the ticket flow the Apple apps already use — publish `idfon-live-*`,
//! subscribe the peer's ticket — not the daemon harness's session-scoped
//! `calls/<id>` path):
//!
//! 1. The caller publishes its mic and sends an `IDFON-LIVE/1 action=start
//!    ticket=<caller ticket> return_addr=<base64 EndpointAddr>` message. The
//!    holder intercepts it (before Eve sees it) and calls [`start_call`].
//! 2. The holder opens one GPT-Live WS session, subscribes the caller's audio
//!    (decode to s16 24 kHz mono → `session.input_audio.append`), and publishes
//!    its own side (`session.output_audio.delta` → push queue → Live broadcast)
//!    using the codec/rate advertised in the caller's invite.
//! 3. The holder sends the return-leg invite carrying its own ticket, so the
//!    caller subscribes and the call goes two-way (`.calling` → `.inCall`).
//! 4. `action=stop` text, a WS close, or a dead subscriber tears the call
//!    down. One call at a time: a new invite replaces the old one.
//!
//! Without `AI_GATEWAY_API_KEY` in the holder environment calls are not
//! intercepted at all — invite texts fall through to Eve, whose instructions
//! decline them.

use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, StreamExt};
use idfon_core::transport::{IrohTransport, MessageTransport};
use iroh::{EndpointAddr, EndpointId};
use iroh_live::{ticket::LiveTicket, Live};
use moq_audio::{
    encode::{Codec as AudioCodec, Options as AudioOptions},
    Format, Frame as AudioFrame,
};
use moq_media::publish::{AudioSource, LocalBroadcast};
use n0_future::{boxed::BoxStream, stream::unfold};
use serde_json::json;
use tokio_websockets::{ClientBuilder, Message};

const LIVE_URL: &str = "wss://ai-gateway.vercel.sh/v1/live/sessions";
const CHUNK_SAMPLES: usize = 480; // 20 ms of 24 kHz mono
const CHUNK_MS: u64 = 20;
const CALL_BROADCAST: &str = "idfon-live-agent";
const STARTUP_TIMEOUT: Duration = Duration::from_secs(20);
const SESSION_CLOSE_TIMEOUT: Duration = Duration::from_secs(15);
const REPLY_MAX_S: u64 = 120; // ponytail: one spoken turn cap; a real turn-taking policy is a bigger design
const CAPTURE_MAX_BYTES: usize = 24_000 * 2 * REPLY_MAX_S as usize;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct AudioProfile {
    codec: AudioCodec,
    sample_rate: u32,
}

impl Default for AudioProfile {
    fn default() -> Self {
        Self {
            codec: AudioCodec::Opus,
            sample_rate: 48_000,
        }
    }
}

fn parse_audio_profile(codec: Option<&str>, sample_rate: Option<u32>) -> Result<AudioProfile> {
    match (codec, sample_rate) {
        (None, None) => Ok(AudioProfile::default()),
        (Some("opus"), Some(48_000)) => Ok(AudioProfile {
            codec: AudioCodec::Opus,
            sample_rate: 48_000,
        }),
        (Some("pcm"), Some(24_000)) => Ok(AudioProfile {
            codec: AudioCodec::Pcm,
            sample_rate: 24_000,
        }),
        _ => {
            anyhow::bail!("unsupported caller audio profile: codec={codec:?} rate={sample_rate:?}")
        }
    }
}

#[derive(Clone, Default)]
struct CallDiagnostics(Option<Arc<CallDiagnosticsInner>>);

struct CallDiagnosticsInner {
    dir: PathBuf,
    started: Instant,
    buffers: Mutex<CaptureBuffers>,
}

#[derive(Default)]
struct CaptureBuffers {
    caller_wire: Vec<u8>,
    caller_to_gpt: Vec<u8>,
    gpt_output: Vec<u8>,
    published: Vec<u8>,
    trace: Vec<String>,
}

impl CallDiagnostics {
    fn new() -> Self {
        let root = std::env::var_os("IDFON_AUDIO_CAPTURE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::temp_dir().join("idfon-audio-captures"));
        let dir = root.join(format!("call-{}-{}", std::process::id(), rand_suffix()));
        match std::fs::create_dir_all(&dir) {
            Ok(()) => {
                eprintln!(
                    "[eve-idfon-channel] audio diagnostics dir={}",
                    dir.display()
                );
                Self(Some(Arc::new(CallDiagnosticsInner {
                    dir,
                    started: Instant::now(),
                    buffers: Mutex::new(CaptureBuffers::default()),
                })))
            }
            Err(error) => {
                eprintln!("[eve-idfon-channel] audio diagnostics disabled: {error}");
                Self::default()
            }
        }
    }

    fn capture(&self, lane: &str, bytes: &[u8]) {
        let Some(inner) = &self.0 else { return };
        let Ok(mut buffers) = inner.buffers.lock() else {
            return;
        };
        let target = match lane {
            "caller_wire" => &mut buffers.caller_wire,
            "caller_to_gpt" => &mut buffers.caller_to_gpt,
            "gpt_output" => &mut buffers.gpt_output,
            "published" => &mut buffers.published,
            _ => return,
        };
        let count = bytes
            .len()
            .min(CAPTURE_MAX_BYTES.saturating_sub(target.len()));
        target.extend_from_slice(&bytes[..count]);
    }

    fn trace(&self, mut event: serde_json::Value) {
        let Some(inner) = &self.0 else { return };
        if let Some(object) = event.as_object_mut() {
            object.insert(
                "elapsed_us".into(),
                serde_json::json!(inner.started.elapsed().as_micros()),
            );
        }
        if let Ok(line) = serde_json::to_string(&event) {
            if let Ok(mut buffers) = inner.buffers.lock() {
                if buffers.trace.len() < 100_000 {
                    buffers.trace.push(line);
                }
            }
        }
    }

    fn finish(&self) {
        let Some(inner) = &self.0 else { return };
        let Ok(buffers) = inner.buffers.lock() else {
            return;
        };
        for (name, pcm) in [
            ("caller-wire.wav", &buffers.caller_wire),
            ("caller-to-gpt.wav", &buffers.caller_to_gpt),
            ("gpt-output.wav", &buffers.gpt_output),
            ("published.wav", &buffers.published),
        ] {
            if let Err(error) = write_pcm_wav(&inner.dir.join(name), pcm) {
                eprintln!("[eve-idfon-channel] audio capture write failed {name}: {error}");
            }
        }
        if let Err(error) = std::fs::write(
            inner.dir.join("timing.jsonl"),
            buffers.trace.join("\n") + "\n",
        ) {
            eprintln!("[eve-idfon-channel] timing trace write failed: {error}");
        }
    }
}

fn write_pcm_wav(path: &std::path::Path, pcm: &[u8]) -> std::io::Result<()> {
    let pcm = &pcm[..pcm.len() & !1];
    let data_len = pcm.len() as u32;
    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&24_000u32.to_le_bytes());
    wav.extend_from_slice(&48_000u32.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(pcm);
    std::fs::write(path, wav)
}

struct LiveInvite {
    is_start: bool,
    is_stop: bool,
    ticket: Option<LiveTicket>,
    return_addr: Option<EndpointAddr>,
    audio_codec: Option<String>,
    audio_sample_rate: Option<u32>,
}

fn parse_invite(text: &str) -> Option<LiveInvite> {
    let body = text.strip_prefix("IDFON-LIVE/1\naction=")?;
    let (action, rest) = body.split_once('\n').unwrap_or((body, ""));
    let ticket = rest
        .lines()
        .find_map(|line| line.strip_prefix("ticket="))
        .filter(|value| !value.is_empty())
        .and_then(|value| value.parse().ok());
    let return_addr = rest
        .lines()
        .find_map(|line| line.strip_prefix("return_addr="))
        .and_then(|value| BASE64.decode(value).ok())
        .and_then(|bytes| serde_json::from_slice(&bytes).ok());
    let audio_codec = rest
        .lines()
        .find_map(|line| line.strip_prefix("audio_codec="))
        .map(str::to_owned);
    let audio_sample_rate = rest
        .lines()
        .find_map(|line| line.strip_prefix("audio_sample_rate="))
        .and_then(|value| value.parse().ok());
    Some(LiveInvite {
        is_start: action == "start",
        is_stop: action == "stop",
        ticket,
        return_addr,
        audio_codec,
        audio_sample_rate,
    })
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
        eprintln!("[eve-idfon-channel] call stopped: {reason}");
    }
}

/// Intercepts call-control texts. Returns `true` when the message was consumed
/// (a call start/stop this holder owns) and must not reach Eve.
pub async fn handle_live_text(
    text: &str,
    sender_peer_id: &str,
    sender_endpoint_id: &str,
    transport: &Arc<IrohTransport>,
    key: &SigningKey,
    holder_endpoint_id: &str,
) -> Result<bool> {
    let Some(invite) = parse_invite(text) else {
        return Ok(false);
    };
    if invite.is_stop {
        stop_active_call(&format!("peer {sender_peer_id} hung up"));
        return Ok(true);
    }
    if !invite.is_start {
        return Ok(true); // unknown action: consume rather than confuse the agent
    }
    // Without a gateway key the agent (text/memo path) handles the turn; its
    // instructions decline the call politely.
    let api_key = match std::env::var("AI_GATEWAY_API_KEY") {
        Ok(key) if !key.is_empty() => key,
        _ => return Ok(false),
    };
    let profile = parse_audio_profile(invite.audio_codec.as_deref(), invite.audio_sample_rate)?;
    let ticket = invite
        .ticket
        .ok_or_else(|| anyhow!("live call start is missing its media ticket"))?;
    let endpoint_id = sender_endpoint_id
        .parse::<EndpointId>()
        .map_err(|error| anyhow!("invalid caller endpoint id: {error}"))?;
    eprintln!(
        "[eve-idfon-channel] call invite peer={sender_peer_id} explicit_return_addr={} response_codec={} response_rate={}",
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
    if let Err(error) = start_call(
        ticket,
        caller_addr,
        sender_peer_id.to_string(),
        holder_endpoint_id,
        Arc::clone(transport),
        key.clone(),
        api_key,
        profile,
    )
    .await
    {
        eprintln!("[eve-idfon-channel] call failed: {error:#}");
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
) -> Result<()> {
    stop_active_call("replaced by a newer call");
    let stop = Arc::new(AtomicBool::new(false));
    *active_call().lock().expect("call mutex poisoned") = Some(CallHandle {
        stop: Arc::clone(&stop),
    });

    // Publish our side first: the caller may subscribe the instant our return
    // leg lands, so the broadcast must exist and be announcing.
    let live = Arc::new(
        Live::from_env()
            .await
            .context("live endpoint")?
            .with_router()
            .spawn(),
    );
    let broadcast = live
        .publish(CALL_BROADCAST)
        .context("publish call broadcast")?;
    let diagnostics = CallDiagnostics::new();
    let out_bus = QueueSink::new(diagnostics.clone());
    let publisher = tokio::spawn(publish_gpt_audio(
        broadcast,
        out_bus.clone(),
        Arc::clone(&stop),
        profile,
    ));
    let own_ticket = LiveTicket::new(live.endpoint().id(), CALL_BROADCAST).serialize();

    // Return-leg invite: the caller subscribes to our side; its UI leaves
    // `.calling` and audio flows both ways.
    let call_id = rand_suffix();
    let envelope = idfon_core::sign_message(
        &key,
        holder_endpoint_id.to_string(),
        format!("eve_call_return_{call_id}"),
        idfon_protocol::MessageContent::Text {
            text: format!(
                "IDFON-LIVE/1\naction=start\nticket={own_ticket}\nreturn=1\naudio_codec={}\naudio_sample_rate={}",
                profile.codec, profile.sample_rate
            ),
        },
        format!("eve-call-{caller_peer_id}-return-{call_id}"),
        None,
    )
    .context("sign return-leg invite")?;
    // A caller can still be settling when the invite lands (launch-time dial);
    // retries reuse this call's unique idempotency key and are safe.
    let mut sent = false;
    for attempt in 0..4 {
        match transport.send(&caller_addr, &envelope).await {
            Ok(_) => {
                sent = true;
                break;
            }
            Err(error) => {
                eprintln!("[eve-idfon-channel] return-leg send retry {attempt}: {error}");
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
    if !sent {
        stop.store(true, Ordering::Relaxed);
        let _ = publisher.await;
        diagnostics.finish();
        anyhow::bail!("return-leg invite never acknowledged");
    }
    eprintln!("[eve-idfon-channel] call accepted from {caller_peer_id}, return leg sent");

    // Drive the GPT-Live session + caller audio until the call ends. The
    // timeout only bounds startup; afterwards the task keeps running the call
    // in the background and cleans up through the `stop` flag.
    let task = tokio::spawn(async move {
        let result = run_session(
            caller_ticket,
            out_bus,
            api_key,
            Arc::clone(&stop),
            diagnostics.clone(),
            profile,
        )
        .await;
        stop.store(true, Ordering::Relaxed);
        let _ = publisher.await;
        diagnostics.finish();
        if let Err(error) = &result {
            eprintln!("[eve-idfon-channel] live session failed: {error:#}");
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

    #[test]
    fn pcm_capture_wav_and_delta_byte_carry_are_valid() {
        let sink = QueueSink::new(CallDiagnostics::default());
        assert_eq!(sink.push(&[0x34]), (0, 0));
        assert_eq!(sink.push(&[0x12, 0x78, 0x56]), (2, 0));
        let queue = sink.queue.lock().unwrap();
        assert_eq!(
            queue.samples.iter().copied().collect::<Vec<_>>(),
            [0x1234, 0x5678]
        );
        drop(queue);
        let mut output = [9i16; 4];
        assert_eq!(
            fill_audio_frame(&mut VecDeque::from([7, 8]), &mut output),
            2
        );
        assert_eq!(output, [7, 8, 0, 0]);

        let path = std::env::temp_dir().join(format!("idfon-audio-{}.wav", rand_suffix()));
        write_pcm_wav(&path, &[0x34, 0x12]).unwrap();
        let wav = std::fs::read(&path).unwrap();
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(wav[24..28].try_into().unwrap()), 24_000);
        assert_eq!(&wav[44..], &[0x34, 0x12]);
        std::fs::remove_file(path).unwrap();
    }
}

fn fill_audio_frame(queue: &mut VecDeque<i16>, output: &mut [i16]) -> usize {
    let available = queue.len().min(output.len());
    for sample in &mut output[..available] {
        *sample = queue.pop_front().unwrap_or(0);
    }
    output[available..].fill(0);
    output.len() - available
}

fn rand_suffix() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!("{nanos:08x}")
}

/// PCM hand-off from the GPT-Live reader into the broadcast encoder: s16le
/// samples (24 kHz mono), bounded so a stall cannot ratchet memory.
#[derive(Default)]
struct QueueData {
    samples: VecDeque<i16>,
    trailing_byte: Option<u8>,
}

#[derive(Clone)]
struct QueueSink {
    queue: Arc<Mutex<QueueData>>,
    diagnostics: CallDiagnostics,
}

impl QueueSink {
    fn new(diagnostics: CallDiagnostics) -> Self {
        Self {
            queue: Arc::new(Mutex::new(QueueData {
                samples: VecDeque::with_capacity(1 << 13),
                trailing_byte: None,
            })),
            diagnostics,
        }
    }

    fn push(&self, bytes: &[u8]) -> (usize, usize) {
        let Ok(mut queue) = self.queue.lock() else {
            return (0, 0);
        };
        let mut offset = 0;
        if let Some(previous) = queue.trailing_byte.take() {
            if let Some(&first) = bytes.first() {
                queue
                    .samples
                    .push_back(i16::from_le_bytes([previous, first]));
                offset = 1;
            } else {
                queue.trailing_byte = Some(previous);
            }
        }
        while offset + 1 < bytes.len() {
            queue
                .samples
                .push_back(i16::from_le_bytes([bytes[offset], bytes[offset + 1]]));
            offset += 2;
        }
        if offset < bytes.len() {
            queue.trailing_byte = Some(bytes[offset]);
        }
        // Cap at ~10 s of 24 kHz audio; drop the oldest.
        let mut dropped = 0;
        while queue.samples.len() > 240_000 {
            queue.samples.pop_front();
            dropped += 1;
        }
        (queue.samples.len(), dropped)
    }
}

/// The GPT-Live session: caller audio in, spoken reply out, until hangup.
async fn run_session(
    caller_ticket: LiveTicket,
    out_bus: QueueSink,
    api_key: String,
    stop: Arc<AtomicBool>,
    diagnostics: CallDiagnostics,
    profile: AudioProfile,
) -> Result<()> {
    let ws = connect_live(&api_key).await?;
    let (mut ws_tx, mut ws_rx) = ws.split();
    eprintln!("[eve-idfon-channel] GPT-Live session ready");

    // WS → broadcast: decode base64 s16 24 kHz chunks straight into the queue.
    let reader_stop = Arc::clone(&stop);
    let reader_diagnostics = diagnostics.clone();
    let session_finalized = Arc::new(AtomicBool::new(false));
    let reader_finalized = Arc::clone(&session_finalized);
    let mut reader = tokio::spawn(async move {
        let mut output_chunks = 0usize;
        let mut output_bytes = 0usize;
        let mut input_text_chars = 0usize;
        let mut output_text_chars = 0usize;
        let mut finalized = false;
        while let Some(event) = ws_rx.next().await {
            let message = match event {
                Ok(message) => message,
                Err(error) => {
                    eprintln!("[eve-idfon-channel] GPT-Live websocket read failed: {error}");
                    break;
                }
            };
            let Some(text) = message.as_text() else {
                continue;
            };
            let Ok(event) = serde_json::from_str::<serde_json::Value>(text) else {
                eprintln!("[eve-idfon-channel] ignored non-JSON GPT-Live event");
                continue;
            };
            match event["type"].as_str().unwrap_or_default() {
                "session.input_transcript.delta" => {
                    input_text_chars += event["delta"].as_str().unwrap_or_default().len();
                    eprintln!(
                        "[eve-idfon-channel] GPT-Live input transcript chars={input_text_chars}"
                    );
                }
                "session.output_transcript.delta" => {
                    output_text_chars += event["delta"].as_str().unwrap_or_default().len();
                    eprintln!(
                        "[eve-idfon-channel] GPT-Live output transcript chars={output_text_chars}"
                    );
                }
                "session.output_audio.delta" => {
                    if let Some(delta) = event["delta"].as_str().and_then(|d| BASE64.decode(d).ok())
                    {
                        output_chunks += 1;
                        output_bytes += delta.len();
                        reader_diagnostics.capture("gpt_output", &delta);
                        let (queue_samples, dropped_samples) = out_bus.push(&delta);
                        reader_diagnostics.trace(json!({
                            "event": "gpt_audio_delta",
                            "chunk": output_chunks,
                            "bytes": delta.len(),
                            "queue_samples": queue_samples,
                            "dropped_samples": dropped_samples,
                        }));
                        if output_chunks == 1 || output_chunks % 50 == 0 {
                            eprintln!("[eve-idfon-channel] GPT-Live audio out chunks={output_chunks} bytes={output_bytes}");
                        }
                    }
                }
                "session.closed" => {
                    finalized = true;
                    reader_finalized.store(true, Ordering::Relaxed);
                    eprintln!(
                        "[eve-idfon-channel] GPT-Live session closed usage={}",
                        event["usage"]
                    );
                    break;
                }
                "error" => {
                    eprintln!("[eve-idfon-channel] GPT-Live error: {}", event["error"]);
                    break;
                }
                _ => {}
            }
        }
        reader_stop.store(true, Ordering::Relaxed);
        eprintln!(
            "[eve-idfon-channel] GPT-Live reader done finalized={finalized} audio_chunks={output_chunks} audio_bytes={output_bytes} input_text_chars={input_text_chars} output_text_chars={output_text_chars}"
        );
        finalized
    });

    // Caller audio → WS; on hangup, cancel the pump and close GPT-Live cleanly.
    let pacer_stop = Arc::clone(&stop);
    let pacer_diagnostics = diagnostics.clone();
    let pacer_finalized = Arc::clone(&session_finalized);
    let mut pacer = tokio::spawn(async move {
        let pump_stop = Arc::clone(&pacer_stop);
        let result = tokio::select! {
            _ = async {
                while !pacer_stop.load(Ordering::Relaxed) {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            } => Ok(()),
            result = pump_caller_audio(caller_ticket, &mut ws_tx, pump_stop, pacer_diagnostics, profile) => result,
        };
        if let Err(error) = result {
            eprintln!("[eve-idfon-channel] caller audio ended: {error:#}");
        }
        if !pacer_finalized.load(Ordering::Relaxed) {
            let close = Message::text(json!({"type": "session.close"}).to_string());
            match tokio::time::timeout(Duration::from_secs(2), ws_tx.send(close)).await {
                Ok(Ok(())) => eprintln!("[eve-idfon-channel] GPT-Live session.close sent"),
                Ok(Err(error)) => {
                    eprintln!("[eve-idfon-channel] GPT-Live session.close failed: {error}")
                }
                Err(_) => eprintln!("[eve-idfon-channel] GPT-Live session.close timed out"),
            }
        }
        pacer_stop.store(true, Ordering::Relaxed);
    });

    let finalized = tokio::select! {
        result = &mut reader => {
            stop.store(true, Ordering::Relaxed);
            if let Err(error) = tokio::time::timeout(Duration::from_secs(2), &mut pacer).await {
                eprintln!("[eve-idfon-channel] audio pump cleanup timed out: {error}");
                pacer.abort();
            }
            match result {
                Ok(finalized) => finalized,
                Err(error) => {
                    eprintln!("[eve-idfon-channel] GPT-Live reader task failed: {error}");
                    false
                }
            }
        }
        result = &mut pacer => {
            if let Err(error) = result {
                eprintln!("[eve-idfon-channel] caller audio task failed: {error}");
            }
            match tokio::time::timeout(SESSION_CLOSE_TIMEOUT, &mut reader).await {
                Ok(Ok(finalized)) => finalized,
                Ok(Err(error)) => {
                    eprintln!("[eve-idfon-channel] GPT-Live reader task failed: {error}");
                    false
                }
                Err(_) => {
                    eprintln!("[eve-idfon-channel] GPT-Live close timed out; dropping websocket reader");
                    reader.abort();
                    let _ = reader.await;
                    false
                }
            }
        }
    };
    if !finalized {
        eprintln!("[eve-idfon-channel] GPT-Live finalization unconfirmed");
    }
    stop_active_call("session ended");
    Ok(())
}

/// Opens the GPT-Live session for one call.
async fn connect_live(
    api_key: &str,
) -> Result<
    tokio_websockets::WebSocketStream<tokio_websockets::MaybeTlsStream<tokio::net::TcpStream>>,
> {
    eprintln!("[eve-idfon-channel] connecting to GPT-Live");
    let builder = ClientBuilder::from_uri(LIVE_URL.parse().context("parse live url")?)
        .add_header(
            "authorization".parse().context("header name")?,
            format!("Bearer {api_key}")
                .parse()
                .context("header value")?,
        )
        .context("auth header")?;
    let (mut ws, _response) = builder.connect().await.context("connect GPT-Live")?;
    ws.send(Message::text(
        json!({
            "type": "session.start",
            "session": {
                "model": "openai/gpt-live-1",
                "store": false,
                "audio": { "format": { "type": "audio/pcm", "rate": 24_000 } },
                "instructions": "You are on a live phone call with one person. \
                 Greet them briefly when the call connects, then converse naturally. \
                 Keep spoken turns short and conversational, like a phone call. \
                 Plain speech only: no markdown, no lists, no emoji.",
            },
        })
        .to_string(),
    ))
    .await
    .context("send session.start")?;
    tokio::time::timeout(Duration::from_secs(15), async {
        while let Some(message) = ws.next().await {
            let message = message.context("read GPT-Live startup event")?;
            let Some(text) = message.as_text() else {
                continue;
            };
            let event: serde_json::Value =
                serde_json::from_str(text).context("parse GPT-Live startup event")?;
            match event["type"].as_str().unwrap_or_default() {
                "session.started" => return Ok::<(), anyhow::Error>(()),
                "error" => anyhow::bail!("GPT-Live session.start rejected: {}", event["error"]),
                "session.closed" => anyhow::bail!("GPT-Live closed during session.start"),
                _ => {}
            }
        }
        anyhow::bail!("GPT-Live websocket closed before session.started")
    })
    .await
    .context("GPT-Live session.start timed out")??;
    eprintln!("[eve-idfon-channel] GPT-Live session.started");
    Ok(ws)
}

/// Subscribes the caller's mic broadcast (retries cover the catalog announce
/// race) and streams it to GPT-Live, paced at 20 ms.
async fn pump_caller_audio<S>(
    ticket: LiveTicket,
    ws_tx: &mut S,
    stop: Arc<AtomicBool>,
    diagnostics: CallDiagnostics,
    expected_profile: AudioProfile,
) -> Result<()>
where
    S: futures_util::Sink<Message> + Unpin + Send,
    S::Error: std::fmt::Display,
{
    // Fresh endpoint per attempt (negative-caching lesson from blob.rs);
    // the caller's catalog announce may still be propagating.
    let mut sub = None;
    for attempt in 0..6 {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::N0)
            .bind()
            .await
            .context("caller subscribe endpoint")?;
        let live = Live::builder(endpoint).spawn();
        match live
            .subscribe(ticket.endpoint.clone(), &ticket.broadcast_name)
            .await
        {
            Ok(s) => {
                sub = Some((live, s));
                break;
            }
            Err(error) => {
                eprintln!("[eve-idfon-channel] caller subscribe retry {attempt}: {error:#}");
                live.shutdown().await;
            }
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    let Some((_live, subscription)) = sub else {
        return Err(anyhow!("caller broadcast never announced"));
    };
    let broadcast = subscription.broadcast();
    let catalog = broadcast.catalog();
    let name = catalog
        .first_audio()
        .ok_or_else(|| anyhow!("caller broadcast has no audio track"))?
        .to_string();
    let config = catalog
        .audio()
        .get(&name)
        .ok_or_else(|| anyhow!("caller audio catalog entry disappeared"))?
        .clone();
    let actual_codec = config.codec.to_string();
    let actual_profile = parse_audio_profile(Some(&actual_codec), Some(config.sample_rate))?;
    anyhow::ensure!(
        actual_profile == expected_profile,
        "caller invite requested {expected_profile:?}, but media catalog advertises {actual_profile:?}"
    );
    eprintln!(
        "[eve-idfon-channel] caller track={name} codec={} rate={}",
        actual_codec, config.sample_rate
    );
    // Decode to GPT-Live's PCM format; a matching 24 kHz PCM track needs no resampling.
    let mut decode = moq_audio::decode::Config::new();
    decode.format = Format::S16;
    decode.sample_rate = Some(24_000);
    decode.channels = Some(1);
    decode.latency_max = Some(Duration::from_millis(100));
    let mut consumer =
        moq_audio::decode::Consumer::new(broadcast.consumer(), &config, &name, decode).await?;
    eprintln!("[eve-idfon-channel] caller audio subscribed track={name}");

    const MAX_INPUT_BUFFER: usize = 12_000; // 500 ms at 24 kHz
    let (frame_tx, mut frame_rx) = tokio::sync::mpsc::channel(8);
    let read_stop = Arc::clone(&stop);
    let mut reader = tokio::spawn(async move {
        while !read_stop.load(Ordering::Relaxed) {
            match consumer.read().await {
                Ok(Some(frame)) => {
                    if frame_tx.send(Ok(frame)).await.is_err() {
                        break;
                    }
                }
                Ok(None) => {
                    let _ = frame_tx.send(Err("caller track ended".into())).await;
                    break;
                }
                Err(error) => {
                    let _ = frame_tx.send(Err(error.to_string())).await;
                    break;
                }
            }
        }
    });
    let mut tick = tokio::time::interval_at(
        tokio::time::Instant::now() + Duration::from_millis(CHUNK_MS),
        Duration::from_millis(CHUNK_MS),
    );
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut input = VecDeque::with_capacity(MAX_INPUT_BUFFER);
    let mut sent_samples = 0u64;
    let mut chunks = 0u64;
    let mut input_frames = 0u64;
    let mut underflow_samples = 0u64;
    let mut dropped_samples = 0u64;
    let mut last_arrival: Option<Instant> = None;
    let mut expected_pts_us: Option<u128> = None;
    let mut media_origin_pts: Option<i128> = None;

    loop {
        tokio::select! {
            _ = tick.tick() => {
                if stop.load(Ordering::Relaxed) { break; }
                let mut pcm = [0i16; CHUNK_SAMPLES];
                let missing = fill_audio_frame(&mut input, &mut pcm);
                underflow_samples += missing as u64;
                let queue_samples = input.len();
                let bytes: Vec<u8> = pcm.iter().flat_map(|sample| sample.to_le_bytes()).collect();
                diagnostics.capture("caller_to_gpt", &bytes);
                diagnostics.trace(json!({
                    "event": "caller_input_append",
                    "chunk": chunks + 1,
                    "samples": CHUNK_SAMPLES,
                    "queue_samples": queue_samples,
                    "silence_samples": missing,
                    "total_silence_samples": underflow_samples,
                }));
                ws_tx
                    .send(Message::text(json!({
                        "type": "session.input_audio.append",
                        "audio": BASE64.encode(&bytes),
                    }).to_string()))
                    .await
                    .map_err(|error| anyhow!("GPT-Live send: {error}"))?;
                chunks += 1;
                sent_samples += CHUNK_SAMPLES as u64;
                if chunks == 1 || chunks % 50 == 0 {
                    eprintln!("[eve-idfon-channel] caller appends={chunks} source_frames={input_frames} silence_samples={underflow_samples} queue_samples={queue_samples}");
                }
                if sent_samples >= REPLY_MAX_S * 24_000 { break; }
            }
            item = frame_rx.recv() => {
                match item {
                    Some(Ok(frame)) => {
                        input_frames += 1;
                        let samples = frame.data.len() / 2;
                        let peak = frame.data.chunks_exact(2)
                            .map(|pair| i16::from_le_bytes([pair[0], pair[1]]).unsigned_abs())
                            .max().unwrap_or(0);
                        let arrived = Instant::now();
                        let arrival_gap_us = last_arrival.map(|last| arrived.duration_since(last).as_micros()).unwrap_or(0);
                        let pts_us = frame.timestamp.as_micros();
                        let media_gap_us = expected_pts_us.map(|expected| pts_us.saturating_sub(expected)).unwrap_or(0);
                        expected_pts_us = Some(pts_us + samples as u128 * 1_000_000 / 24_000);
                        last_arrival = Some(arrived);
                        diagnostics.capture("caller_wire", &frame.data);
                        diagnostics.trace(json!({
                            "event": "caller_audio_frame",
                            "frame": input_frames,
                            "pts_us": pts_us,
                            "arrival_gap_us": arrival_gap_us,
                            "media_gap_us": media_gap_us,
                            "samples": samples,
                            "peak": peak,
                        }));
                        if arrival_gap_us > 30_000 || media_gap_us > 1_000 {
                            eprintln!("[eve-idfon-channel] caller timing gap arrival={arrival_gap_us}us media={media_gap_us}us pts={pts_us} samples={samples}");
                        }
                        let cursor = sent_samples + dropped_samples + input.len() as u64;
                        let origin = *media_origin_pts.get_or_insert_with(|| {
                            pts_us as i128 - (cursor * 1_000_000 / 24_000) as i128
                        });
                        let target = ((pts_us as i128 - origin).max(0) as u64 * 24_000) / 1_000_000;
                        let media_silence = target.saturating_sub(cursor);
                        if media_silence > 0 {
                            input.extend(std::iter::repeat(0).take(media_silence as usize));
                        }
                        let cursor_after_gap = sent_samples + dropped_samples + input.len() as u64;
                        let late_samples = cursor_after_gap.saturating_sub(target).min(samples as u64);
                        if late_samples > 0 {
                            diagnostics.trace(json!({
                                "event": "caller_audio_late",
                                "frame": input_frames,
                                "dropped_samples": late_samples,
                            }));
                        }
                        input.extend(
                            frame.data
                                .chunks_exact(2)
                                .skip(late_samples as usize)
                                .map(|pair| i16::from_le_bytes([pair[0], pair[1]])),
                        );
                        while input.len() > MAX_INPUT_BUFFER {
                            input.pop_front();
                            dropped_samples += 1;
                        }
                    }
                    Some(Err(reason)) => {
                        eprintln!("[eve-idfon-channel] caller audio ended: {reason}");
                        break;
                    }
                    None => break,
                }
            }
        }
    }
    reader.abort();
    let _ = (&mut reader).await;
    if dropped_samples > 0 {
        eprintln!("[eve-idfon-channel] caller input queue dropped {dropped_samples} old samples");
    }
    Ok(())
}

/// Publishes one 20 ms frame per clock tick; underflow is silence, not a stalled track.
async fn publish_gpt_audio(
    broadcast: LocalBroadcast,
    sink: QueueSink,
    stop: Arc<AtomicBool>,
    profile: AudioProfile,
) {
    let stream_stop = Arc::clone(&stop);
    let mut tick = tokio::time::interval_at(
        tokio::time::Instant::now() + Duration::from_millis(CHUNK_MS),
        Duration::from_millis(CHUNK_MS),
    );
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let stream: BoxStream<AudioFrame> = Box::pin(unfold(
        (
            sink,
            0u64,
            0u64,
            0u64,
            stream_stop,
            tick,
            None::<Instant>,
            profile,
        ),
        move |(sink, pts, frames, underflow_samples, stop, mut tick, last_tick, profile)| async move {
            tick.tick().await;
            if stop.load(Ordering::Relaxed) {
                return None;
            }
            let mut data = vec![0i16; CHUNK_SAMPLES];
            let mut queue = sink.queue.lock().ok()?;
            let missing = fill_audio_frame(&mut queue.samples, &mut data);
            let available = CHUNK_SAMPLES - missing;
            drop(queue);
            let frame = frames + 1;
            let total_underflow = underflow_samples + missing as u64;
            let now = Instant::now();
            let tick_gap_us = last_tick
                .map(|last| now.duration_since(last).as_micros())
                .unwrap_or(CHUNK_MS as u128 * 1_000);
            let pts_delta = if tick_gap_us > 30_000 {
                tick_gap_us as u64
            } else {
                CHUNK_MS * 1_000
            };
            if frame == 1 || frame % 50 == 0 {
                eprintln!("[eve-idfon-channel] audio frame={frame} queue_samples={available} underflow_samples={missing} total_underflow={total_underflow}");
            }
            let bytes: Vec<u8> = data
                .iter()
                .flat_map(|sample| sample.to_le_bytes())
                .collect();
            sink.diagnostics.capture("published", &bytes);
            sink.diagnostics.trace(json!({
                "event": "published_audio_frame",
                "frame": frame,
                "pts_us": pts,
                "tick_gap_us": tick_gap_us,
                "queue_samples": available,
                "underflow_samples": missing,
                "total_underflow_samples": total_underflow,
                "codec": profile.codec.to_string(),
                "sample_rate": profile.sample_rate,
            }));
            let timestamp = moq_net::Timestamp::from_micros(pts).ok()?;
            Some((
                AudioFrame::new(bytes::Bytes::from(bytes), timestamp),
                (
                    sink,
                    pts + pts_delta,
                    frame,
                    total_underflow,
                    stop,
                    tick,
                    Some(now),
                    profile,
                ),
            ))
        },
    ));
    let mut options = AudioOptions::default();
    options.codec = profile.codec;
    options.sample_rate = Some(profile.sample_rate);
    broadcast.audio().set_with(
        AudioSource::Frames {
            input: moq_audio::encode::Input {
                format: Format::S16,
                sample_rate: 24_000,
                channels: 1,
            },
            frames: stream,
        },
        options,
    );
    // The publish tasks live inside the broadcast handle; park until the call
    // ends, then drop (which ends the broadcast).
    while !stop.load(Ordering::Relaxed) {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    eprintln!("[eve-idfon-channel] call broadcast closed");
}
