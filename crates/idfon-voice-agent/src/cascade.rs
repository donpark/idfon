//! Cascade backend: caller audio → STT → agent turn → TTS → return audio.
//!
//! The engine is built from the voice agent's `engine` config via
//! [`idfon_voice::providers::build_engine`] (any OpenAI-compatible provider, or
//! a split such as Deepgram STT + ElevenLabs TTS). It sits behind the
//! [`VoiceBackend`] seam, so swapping providers changes nothing above.
//!
//! TTS streams two ways: agent-output deltas arrive on `media.deltas` and are
//! fed to `StreamingSpeaker` (envelope strip, clause batching, retry dedupe);
//! and providers that support it push synthesized audio straight to an
//! [`AudioSink`] as they produce it (`tts_with_sink`). Batch providers return
//! chunks, which are routed through the same sink.

use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use idfon_voice::{
    is_cancellable, normalize_for_speech, AudioFormat, AudioSink, BargeInController,
    EchoSuppressor, EndpointEvent, MessageDelta, PcmChunk, StreamingSpeaker, VoiceEngine,
};
use serde_json::Value;
use tokio::time::MissedTickBehavior;

use crate::metrics::TurnMetrics;
use crate::{
    send_call_transcript, strip_envelopes, BackendFuture, VoiceBackend, VoiceBackendFactory,
    VoiceMedia,
};
use idfon_protocol::CallSpeaker;

/// Cascade: STT the caller, run a normal agent turn, TTS the reply.
pub struct CascadeBackend {
    engine: Arc<dyn VoiceEngine>,
    provider: String,
    format: AudioFormat,
    /// Who runs each half (hybrid `voice_route`): `false` = caller on-device.
    stt_server: bool,
    tts_server: bool,
}

impl VoiceBackend for CascadeBackend {
    fn name(&self) -> &str {
        "cascade"
    }

    fn run(&mut self, media: VoiceMedia) -> BackendFuture<'_> {
        Box::pin(self.run_loop(media))
    }
}

impl CascadeBackend {
    async fn run_loop(&mut self, mut media: VoiceMedia) -> Result<()> {
        let format = self.format;
        let stt_server = self.stt_server;
        let tts_server = self.tts_server;
        let mut stt = if stt_server { Some(self.engine.stt(format)?) } else { None };
        let mut endpointer = if stt_server { Some(self.engine.endpointer(format)?) } else { None };
        let mut tick = tokio::time::interval(Duration::from_millis(200));
        tick.set_missed_tick_behavior(MissedTickBehavior::Delay);

        let mut pending: Option<(u64, u64)> = None; // (stt_ms, caller_audio_ms)
        let mut caller_frames = 0u64;

        // Every synthesized chunk goes through one sink: batch adapters return
        // chunks we forward, streaming adapters call the sink as audio arrives.
        let first_ms = Arc::new(AtomicU64::new(0));
        let audio_ms = Arc::new(AtomicU64::new(0));
        let reply_started = Arc::new(Mutex::new(Instant::now()));
        let sink: AudioSink = {
            let queue = media.audio.clone();
            let first = Arc::clone(&first_ms);
            let audio = Arc::clone(&audio_ms);
            let started = Arc::clone(&reply_started);
            Arc::new(move |chunk: PcmChunk| {
                let elapsed = started
                    .lock()
                    .map(|started| started.elapsed().as_millis() as u64)
                    .unwrap_or(0);
                let _ = first.compare_exchange(0, elapsed.max(1), Ordering::Relaxed, Ordering::Relaxed);
                audio.fetch_add(samples_ms(&chunk, format), Ordering::Relaxed);
                queue.push_samples(&chunk.samples);
            })
        };
        let mut speaker: Option<StreamingSpeaker> = None;
        let mut deltas_seen = false;
        // F6 barge-in state: the counter-based controller, the echo filter over
        // the text being spoken, the turn currently playing, and the turns a
        // barge-in cancelled (their remaining deltas are dropped).
        let mut bargein = BargeInController::new();
        let mut echo = EchoSuppressor::new();
        let mut played_text = String::new();
        let mut current_turn: Option<String> = None;
        let mut cancelled: HashSet<String> = HashSet::new();

        loop {
            tokio::select! {
                item = media.caller.recv(), if stt_server => {
                    let Some(pcm) = item else { break };
                    caller_frames += 1;
                    let stt = stt.as_mut().expect("stt session");
                    let endpointer = endpointer.as_mut().expect("endpointer");
                    let _ = stt.push(&pcm);
                    if let Some(EndpointEvent::SpeechEnded) = endpointer.push(&pcm)? {
                        let playing = bargein.is_playing();
                        let started = Instant::now();
                        if let Some(text) = stt.flush()? {
                            let text = text.trim().to_string();
                            if !text.is_empty() && !echo.is_echo(&text) {
                                match caller_decision(&text, playing, false) {
                                    CallerDecision::Ignore => {
                                        // Backchannel/sub-minimum while the agent
                                        // speaks: keep playing, do not take a turn.
                                    }
                                    CallerDecision::Steer => {
                                        // Before playback an utterance is a steer:
                                        // drop nothing, queue it as the next turn.
                                        if let Some(mut active) = speaker.take() {
                                            emit(active.finish()?, &sink);
                                        }
                                        deltas_seen = false;
                                        first_ms.store(0, Ordering::Relaxed);
                                        audio_ms.store(0, Ordering::Relaxed);
                                        if let Ok(mut started) = reply_started.lock() { *started = Instant::now(); }
                                        pending = Some((
                                            started.elapsed().as_millis() as u64,
                                            caller_frames * idfon_live_media::CHUNK_MS,
                                        ));
                                        media.bridge.record("caller", &text);
                                        let turn_id = media.bridge.inject(&text).await;
                                        send_call_transcript(
                                            &media.platform,
                                            media.bridge.call_id(),
                                            CallSpeaker::Caller,
                                            &turn_id,
                                            &text,
                                            true,
                                        )
                                        .await;
                                    }
                                    CallerDecision::Queue => {
                                        // During playback a cancellable utterance
                                        // cancels: flush the return queue, drop the
                                        // rest of the turn, record what played, and
                                        // queue the caller's new turn.
                                        bargein.barge_in();
                                        if let Some(turn) = current_turn.take() {
                                            bargein.record_truncation(turn.as_str(), played_text.as_str());
                                            media.bridge.record_playback_truncated(&turn, &played_text);
                                            cancelled.insert(turn);
                                        }
                                        media.audio.clear();
                                        speaker = None;
                                        deltas_seen = false;
                                        played_text.clear();
                                        echo.clear_spoken();
                                        first_ms.store(0, Ordering::Relaxed);
                                        audio_ms.store(0, Ordering::Relaxed);
                                        if let Ok(mut started) = reply_started.lock() { *started = Instant::now(); }
                                        pending = Some((
                                            started.elapsed().as_millis() as u64,
                                            caller_frames * idfon_live_media::CHUNK_MS,
                                        ));
                                        media.bridge.record("caller", &text);
                                        let turn_id = media.bridge.inject(&text).await;
                                        send_call_transcript(
                                            &media.platform,
                                            media.bridge.call_id(),
                                            CallSpeaker::Caller,
                                            &turn_id,
                                            &text,
                                            true,
                                        )
                                        .await;
                                    }
                                }
                            }
                        }
                        caller_frames = 0;
                    }
                }
                // STT on-device: the app sends the caller transcript.
                Some(text) = media.caller_text.recv(), if !stt_server => {
                    let text = text.trim().to_string();
                    if !text.is_empty()
                        && !matches!(caller_decision(&text, bargein.is_playing(), false), CallerDecision::Ignore)
                    {
                        if bargein.is_playing() {
                            bargein.barge_in();
                            if let Some(turn) = current_turn.take() {
                                bargein.record_truncation(turn.as_str(), played_text.as_str());
                                media.bridge.record_playback_truncated(&turn, &played_text);
                                cancelled.insert(turn);
                            }
                            media.audio.clear();
                            speaker = None;
                            deltas_seen = false;
                            played_text.clear();
                            echo.clear_spoken();
                        } else if let Some(mut active) = speaker.take() {
                            emit(active.finish()?, &sink);
                        }
                        first_ms.store(0, Ordering::Relaxed);
                        audio_ms.store(0, Ordering::Relaxed);
                        if let Ok(mut started) = reply_started.lock() { *started = Instant::now(); }
                        pending = Some((0, 0));
                        media.bridge.record("caller", &text);
                        let turn_id = media.bridge.inject(&text).await;
                        send_call_transcript(
                            &media.platform,
                            media.bridge.call_id(),
                            CallSpeaker::Caller,
                            &turn_id,
                            &text,
                            true,
                        )
                        .await;
                    }
                }
                Some((turn_id, step, seq, text)) = media.deltas.recv() => {
                    // Deltas for a barge-in-cancelled turn are dropped by turn
                    // id; the counter bump guarantees the old turn is dead while
                    // the queued follow-up (a fresh turn) speaks normally.
                    if tts_server && !cancelled.contains(&turn_id) {
                        if speaker.is_none() {
                            speaker = Some(StreamingSpeaker::new(
                                self.engine.tts_with_sink("default", format, sink.clone())?,
                            ));
                            bargein.playback_started();
                            if let Ok(mut started) = reply_started.lock() { *started = Instant::now(); }
                        }
                        deltas_seen = true;
                        current_turn = Some(turn_id.clone());
                        played_text.push_str(&text);
                        echo.set_spoken(&played_text);
                        let chunks = speaker
                            .as_mut()
                            .expect("speaker just set")
                            .push(MessageDelta::new(turn_id, step, seq, &text))?;
                        emit(chunks, &sink);
                    }
                }
                Some((turn_id, reply)) = media.bridge.next_reply() => {
                    let spoken = strip_envelopes(&reply);
                    // Forget the cancelled turn once its own (empty) reply
                    // arrives, so a later turn reusing the id is not dropped.
                    let cancelled_turn = cancelled.remove(&turn_id);
                    if tts_server {
                        if cancelled_turn {
                            // The reply that barge-in cancelled: never speak it.
                        } else if deltas_seen {
                            if let Some(mut active) = speaker.take() {
                                emit(active.finish()?, &sink);
                            }
                        } else if !spoken.is_empty() {
                            // Fallback: no deltas (older bridge) — speak the whole reply.
                            if let Ok(mut started) = reply_started.lock() { *started = Instant::now(); }
                            bargein.playback_started();
                            current_turn = Some(turn_id.clone());
                            let normalized = normalize_for_speech(&spoken);
                            played_text.clear();
                            played_text.push_str(&normalized);
                            echo.set_spoken(&played_text);
                            let mut whole = StreamingSpeaker::new(
                                self.engine.tts_with_sink("default", format, sink.clone())?,
                            );
                            let chunks = whole.push(MessageDelta::new("reply", 0, 0, &normalized))?;
                            emit(chunks, &sink);
                            let tail = whole.finish()?;
                            emit(tail, &sink);
                        }
                    }
                    let (stt_ms, caller_audio_ms) = pending.take().unwrap_or((0, 0));
                    let mut metrics = TurnMetrics {
                        provider: self.provider.clone(),
                        stt_ms,
                        tts_first_ms: first_ms.load(Ordering::Relaxed).max(1),
                        tts_total_ms: reply_started
                            .lock()
                            .map(|started| started.elapsed().as_millis() as u64)
                            .unwrap_or(0),
                        caller_audio_ms,
                        tts_audio_ms: audio_ms.load(Ordering::Relaxed),
                        tts_chars: spoken.chars().count(),
                        est_cost_usd: None,
                    };
                    metrics.est_cost_usd = metrics.cost_estimate();
                    metrics.log();
                    media.bridge.record("agent", &spoken);
                    if !cancelled_turn && !spoken.is_empty() {
                        send_call_transcript(
                            &media.platform,
                            media.bridge.call_id(),
                            CallSpeaker::Agent,
                            &turn_id,
                            &spoken,
                            true,
                        )
                        .await;
                    }
                    speaker = None;
                    deltas_seen = false;
                    first_ms.store(0, Ordering::Relaxed);
                    audio_ms.store(0, Ordering::Relaxed);
                    // Playback (and its barge-in window) ends once the return
                    // queue has drained; keep the turn/text until then so a
                    // drain-window barge-in can still record truncation.
                    if media.audio.is_empty() {
                        bargein.playback_ended();
                        current_turn = None;
                        played_text.clear();
                        echo.clear_spoken();
                    }
                }
                _ = tick.tick() => {
                    if media.stop.load(Ordering::Relaxed) { break; }
                    // The reply ended but its audio is still draining; close the
                    // barge-in playback window when the queue empties.
                    if bargein.is_playing() && media.audio.is_empty() {
                        bargein.playback_ended();
                        current_turn = None;
                        played_text.clear();
                        echo.clear_spoken();
                    }
                }
            }
        }
        Ok(())
    }
}

fn emit(chunks: Vec<PcmChunk>, sink: &AudioSink) {
    for chunk in chunks {
        sink(chunk);
    }
}

fn samples_ms(chunk: &PcmChunk, format: AudioFormat) -> u64 {
    (chunk.samples.len() as u64 * 1000) / (format.sample_rate as u64 * format.channels.max(1) as u64)
}

/// Builds a [`CascadeBackend`] from the live config.
pub struct CascadeFactory;

impl VoiceBackendFactory for CascadeFactory {
    fn kind(&self) -> &str {
        "cascade"
    }

    fn create(&self, params: &Value) -> Result<Box<dyn VoiceBackend>> {
        // Hybrid ownership from the signed `voice_route` block; absent = both
        // halves on the holder (the original server-cascade).
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
        Ok(Box::new(CascadeBackend {
            // The voice agent's `engine` block selects the provider(s); no
            // block = AI Gateway env.
            engine: idfon_voice::providers::build_engine(params.get("engine"))?,
            provider: provider_label(params.get("engine")),
            format: AudioFormat::PCM_24K_MONO,
            stt_server,
            tts_server,
        }))
    }
}

/// Best-effort provider name(s) for metrics/cost: `stt|tts` for a split engine.
fn provider_label(engine: Option<&Value>) -> String {
    let Some(engine) = engine.filter(|value| !value.is_null()) else {
        return "gateway".to_string();
    };
    let name = |value: &Value| {
        value
            .get("provider")
            .and_then(|provider| provider.as_str())
            .unwrap_or("openai-compatible")
            .to_string()
    };
    if let Some(stt) = engine.get("stt") {
        let tts = engine
            .get("tts")
            .map(&name)
            .unwrap_or_else(|| "openai-compatible".to_string());
        return format!("{}|{}", name(stt), tts);
    }
    name(engine)
}

/// What to do with a caller utterance, per F6: an utterance heard before
/// playback steers (drop nothing); a cancellable utterance during playback
/// cancels playback and queues the follow-up; a backchannel/sub-minimum (or a
/// tool-window utterance) while playing is ignored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CallerDecision {
    Ignore,
    Steer,
    Queue,
}

fn caller_decision(text: &str, playing: bool, in_tool_window: bool) -> CallerDecision {
    if !playing {
        return CallerDecision::Steer;
    }
    if is_cancellable(text, playing, in_tool_window) {
        CallerDecision::Queue
    } else {
        CallerDecision::Ignore
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancellable_speech_during_playback_cancels_and_queues() {
        assert_eq!(caller_decision("stop that", true, false), CallerDecision::Queue);
    }

    #[test]
    fn backchannel_and_sub_minimum_are_ignored_while_playing() {
        assert_eq!(caller_decision("uh-huh", true, false), CallerDecision::Ignore);
        assert_eq!(caller_decision("x", true, false), CallerDecision::Ignore);
        assert_eq!(caller_decision("stop that", true, true), CallerDecision::Ignore);
    }

    #[test]
    fn pre_playback_speech_steers_without_cancelling() {
        assert_eq!(caller_decision("hello there", false, false), CallerDecision::Steer);
        assert_eq!(caller_decision("uh-huh", false, false), CallerDecision::Steer);
    }
}
