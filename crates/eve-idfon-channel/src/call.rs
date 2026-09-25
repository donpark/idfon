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
//!    its own side (`session.output_audio.delta` → push queue → Live
//!    broadcast; the encoder resamples to the codec rate).
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
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use ed25519_dalek::SigningKey;
use futures_util::{SinkExt, StreamExt};
use idfon_core::transport::{IrohTransport, MessageTransport};
use iroh::{EndpointAddr, EndpointId};
use iroh_live::{ticket::LiveTicket, Live};
use moq_audio::{encode::Options as AudioOptions, Format, Frame as AudioFrame};
use moq_media::publish::{AudioSource, LocalBroadcast};
use n0_future::{boxed::BoxStream, stream::unfold};
use serde_json::json;
use tokio_websockets::{ClientBuilder, Message};

const LIVE_URL: &str = "wss://ai-gateway.vercel.sh/v1/live/sessions";
const CHUNK_SAMPLES: usize = 960; // 20 ms of 24 kHz mono
const CHUNK_MS: u64 = 20;
const CALL_BROADCAST: &str = "idfon-live-agent";
const STARTUP_TIMEOUT: Duration = Duration::from_secs(20);
const SESSION_CLOSE_TIMEOUT: Duration = Duration::from_secs(15);
const REPLY_MAX_S: u64 = 120; // ponytail: one spoken turn cap; a real turn-taking policy is a bigger design

struct LiveInvite {
    is_start: bool,
    is_stop: bool,
    ticket: Option<LiveTicket>,
    return_addr: Option<EndpointAddr>,
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
    Some(LiveInvite {
        is_start: action == "start",
        is_stop: action == "stop",
        ticket,
        return_addr,
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
    let ticket = invite
        .ticket
        .ok_or_else(|| anyhow!("live call start is missing its media ticket"))?;
    let endpoint_id = sender_endpoint_id
        .parse::<EndpointId>()
        .map_err(|error| anyhow!("invalid caller endpoint id: {error}"))?;
    eprintln!(
        "[eve-idfon-channel] call invite peer={sender_peer_id} explicit_return_addr={}",
        invite.return_addr.is_some()
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
    let out_bus = QueueSink::new();
    tokio::spawn(publish_gpt_audio(
        broadcast,
        out_bus.clone(),
        Arc::clone(&stop),
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
            text: format!("IDFON-LIVE/1\naction=start\nticket={own_ticket}\nreturn=1"),
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
    anyhow::ensure!(sent, "return-leg invite never acknowledged");
    eprintln!("[eve-idfon-channel] call accepted from {caller_peer_id}, return leg sent");

    // Drive the GPT-Live session + caller audio until the call ends. The
    // timeout only bounds startup; afterwards the task keeps running the call
    // in the background and cleans up through the `stop` flag.
    let task = tokio::spawn(async move {
        let result = run_session(caller_ticket, out_bus, api_key, Arc::clone(&stop)).await;
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
#[derive(Clone)]
struct QueueSink {
    queue: Arc<Mutex<VecDeque<i16>>>,
}

impl QueueSink {
    fn new() -> Self {
        Self {
            queue: Arc::new(Mutex::new(VecDeque::with_capacity(1 << 13))),
        }
    }

    fn push(&self, samples: &[u8]) {
        if let Ok(mut queue) = self.queue.lock() {
            queue.extend(
                samples
                    .chunks_exact(2)
                    .map(|pair| i16::from_le_bytes([pair[0], pair[1]])),
            );
            // Cap at ~10 s of 24 kHz audio; drop the oldest.
            while queue.len() > 240_000 {
                queue.pop_front();
            }
        }
    }
}

/// The GPT-Live session: caller audio in, spoken reply out, until hangup.
async fn run_session(
    caller_ticket: LiveTicket,
    out_bus: QueueSink,
    api_key: String,
    stop: Arc<AtomicBool>,
) -> Result<()> {
    let ws = connect_live(&api_key).await?;
    let (mut ws_tx, mut ws_rx) = ws.split();
    eprintln!("[eve-idfon-channel] GPT-Live session ready");

    // WS → broadcast: decode base64 s16 24 kHz chunks straight into the queue.
    let reader_stop = Arc::clone(&stop);
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
                        out_bus.push(&delta);
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
    let pacer_finalized = Arc::clone(&session_finalized);
    let mut pacer = tokio::spawn(async move {
        let pump_stop = Arc::clone(&pacer_stop);
        let result = tokio::select! {
            _ = async {
                while !pacer_stop.load(Ordering::Relaxed) {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            } => Ok(()),
            result = pump_caller_audio(caller_ticket, &mut ws_tx, pump_stop) => result,
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
    // Decode straight to s16 mono at the GPT-Live rate — the consumer resamples.
    let mut decode = moq_audio::decode::Config::new();
    decode.format = Format::S16;
    decode.sample_rate = Some(24_000);
    decode.channels = Some(1);
    decode.latency_max = Some(Duration::from_millis(100));
    let mut consumer =
        moq_audio::decode::Consumer::new(broadcast.consumer(), &config, &name, decode).await?;
    eprintln!("[eve-idfon-channel] caller audio subscribed track={name}");

    let mut sent = 0u64;
    let mut chunks = 0u64;
    let mut voiced_chunks = 0u64;
    while !stop.load(Ordering::Relaxed) {
        let frame = tokio::time::timeout(Duration::from_millis(200), consumer.read()).await;
        match frame {
            Ok(Ok(Some(frame))) => {
                // Frames arrive ~20 ms worth each; forward them at the pace
                // they arrive (decoders already run on the network clock).
                let samples = frame.data.len() / 2;
                let peak = frame
                    .data
                    .chunks_exact(2)
                    .map(|pair| i16::from_le_bytes([pair[0], pair[1]]).unsigned_abs())
                    .max()
                    .unwrap_or(0);
                chunks += 1;
                if peak > 300 {
                    voiced_chunks += 1;
                }
                ws_tx
                    .send(Message::text(
                        json!({
                            "type": "session.input_audio.append",
                            "audio": BASE64.encode(&frame.data),
                        })
                        .to_string(),
                    ))
                    .await
                    .map_err(|error| anyhow!("GPT-Live send: {error}"))?;
                sent += samples as u64;
                if chunks == 1 || chunks % 50 == 0 {
                    eprintln!("[eve-idfon-channel] caller audio in chunks={chunks} voiced={voiced_chunks} samples={sent} peak={peak}");
                }
                // Cap streamed input (REPLY_MAX_S): stop feeding so Live can
                // finish its turn; the call stays up until the peer hangs up.
                if sent > (REPLY_MAX_S as u64) * 24_000 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(CHUNK_MS)).await;
            }
            Ok(Ok(None)) => break, // caller's broadcast ended (hangup)
            Ok(Err(_)) => break,   // decode error on a 1:1 call = hangup, not a failure
            Err(_) => continue,    // read timeout: keep waiting while the call is up
        }
    }
    Ok(())
}

/// Publishes our call side: drains `queue` at a 20 ms 48 kHz-free cadence —
/// the input is s16 @ 24 kHz and the encoder resamples to the codec rate.
/// Silence while empty so the caller never hears dead air under the greeting.
async fn publish_gpt_audio(broadcast: LocalBroadcast, sink: QueueSink, stop: Arc<AtomicBool>) {
    let stream_stop = Arc::clone(&stop);
    let stream: BoxStream<AudioFrame> = Box::pin(unfold(
        (sink, 0u64, 0u64, stream_stop),
        |(sink, pts, frames, stop)| async move {
            let mut data = vec![0i16; CHUNK_SAMPLES];
            loop {
                if stop.load(Ordering::Relaxed) {
                    return None;
                }
                {
                    let Ok(queue) = sink.queue.lock() else {
                        return None;
                    };
                    if queue.len() >= CHUNK_SAMPLES {
                        break;
                    }
                }
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
            if let Ok(mut queue) = sink.queue.lock() {
                for sample in data.iter_mut() {
                    *sample = queue.pop_front().unwrap_or(0);
                }
            }
            let frame = frames + 1;
            if frame == 1 || frame % 50 == 0 {
                eprintln!("[eve-idfon-channel] audio frames published={frame}");
            }
            let bytes: Vec<u8> = data
                .iter()
                .flat_map(|sample| sample.to_le_bytes())
                .collect();
            let timestamp = moq_net::Timestamp::from_micros(pts).ok()?;
            Some((
                AudioFrame::new(bytes::Bytes::from(bytes), timestamp),
                (sink, pts + CHUNK_MS as u64 * 1_000, frame, stop),
            ))
        },
    ));
    let mut options = AudioOptions::default();
    options.codec = moq_audio::encode::Codec::Opus;
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
