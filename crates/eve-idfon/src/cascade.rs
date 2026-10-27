//! Client-cascade speech units (the reply-delta half of the streaming pair).
//!
//! The Eve channel forwards `message.appended` deltas over the bridge to
//! `IpcFrame::StreamAppend`; a live voice backend consumes them (`deltas::route`).
//! In the client cascade the CALLING APP owns the mouth, so the deltas must
//! reach it as `IDFON-CALL/1` transcript snapshots — the cumulative `partial`
//! of `docs/voice-agent-loop-contract.md` §2, `final: false`, upserted by the
//! app under `turn_id` (its `HybridVoice.streamPartial` seam speaks chunks as
//! they close). The final reply message keeps display + correlation + the
//! barge trim; `played_s` is the app's own accounting here (it owns TTS).
//!
//! Snapshots are throttled (text-so-far, not append-only), so a turn produces
//! a handful of messages rather than one per delta.

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::Result;
use ed25519_dalek::SigningKey;
use idfon_core::transport::{IrohTransport, MessageTransport};
use idfon_core::{peer_id, sign_message_with_ticket};
use idfon_protocol::{encode_call_transcript, CallTranscript, CapabilityTicket, MessageContent};
use idfon_voice::stream::EnvelopeStripper;
use iroh::EndpointAddr;

use crate::{next_message_id, ticket_for_target};

/// Where a peer's units go: the caller's endpoint + conversation, remembered
/// from its inbound turns (`ReplyTarget` is keyed by message id; deltas only
/// carry the peer id).
#[derive(Debug, Clone)]
pub struct PeerRoute {
    pub endpoint_id: String,
    pub conversation: Option<String>,
}

static ROUTES: OnceLock<Mutex<HashMap<String, PeerRoute>>> = OnceLock::new();

fn routes() -> &'static Mutex<HashMap<String, PeerRoute>> {
    ROUTES.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn remember_peer(peer_id: &str, route: PeerRoute) {
    if let Ok(mut routes) = routes().lock() {
        routes.insert(peer_id.to_string(), route);
    }
}

fn route_for(peer_id: &str) -> Option<PeerRoute> {
    routes()
        .lock()
        .ok()
        .and_then(|routes| routes.get(peer_id).cloned())
}

/// Minimum spacing between snapshots for one peer.
const MIN_INTERVAL: Duration = Duration::from_millis(250);

#[derive(Default)]
struct Emitter {
    seen: HashSet<(String, u64, u64)>,
    stripper: EnvelopeStripper,
    text: String,
    emitted_len: usize,
    turn: String,
    last_emit: Option<Instant>,
}

static EMITTERS: OnceLock<Mutex<HashMap<String, Emitter>>> = OnceLock::new();

/// Feed one delta; returns the cumulative snapshot to send with the delta
/// coordinate that closes it (its idempotency key), or `None` when throttled,
/// duplicated, or empty. A provider retry of the same `(turn, step, sequence)`
/// never snapshots twice.
fn push_at(
    peer_id: &str,
    turn_id: &str,
    step_index: u64,
    sequence: u64,
    text: &str,
    now: Instant,
) -> Option<(String, (String, u64, u64))> {
    let emitters = EMITTERS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut guard = emitters.lock().ok()?;
    let emitter = guard.entry(peer_id.to_string()).or_default();
    if emitter.turn != turn_id {
        emitter.turn = turn_id.to_string();
        emitter.seen.clear();
        emitter.stripper = EnvelopeStripper::default();
        emitter.text.clear();
        emitter.emitted_len = 0;
        emitter.last_emit = None;
    }
    if !emitter.seen.insert((turn_id.to_string(), step_index, sequence)) {
        return None;
    }
    emitter.text.push_str(&emitter.stripper.push(text));
    let due = emitter
        .last_emit
        .is_none_or(|at| now.duration_since(at) >= MIN_INTERVAL);
    if !due || emitter.text.len() == emitter.emitted_len {
        return None;
    }
    emitter.last_emit = Some(now);
    emitter.emitted_len = emitter.text.len();
    Some((
        emitter.text.clone(),
        (turn_id.to_string(), step_index, sequence),
    ))
}

/// Feed one delta and send the snapshot when due. Fail-open: a send failure
/// or poisoned registry costs one missing snapshot, never the turn (the final
/// reply message still arrives).
pub async fn push_and_send(
    key: &SigningKey,
    transport: &IrohTransport,
    reply_ticket: Option<&CapabilityTicket>,
    peer: &str,
    turn_id: &str,
    step_index: u64,
    sequence: u64,
    text: &str,
) {
    let Some((snapshot, (turn, step, seq))) = push_at(
        peer,
        turn_id,
        step_index,
        sequence,
        text,
        Instant::now(),
    ) else {
        return;
    };
    let Some(route) = route_for(peer) else {
        return;
    };
    if let Err(error) = send_snapshot(
        key,
        transport,
        reply_ticket,
        peer,
        &route,
        &turn,
        step,
        seq,
        &snapshot,
    )
    .await
    {
        tracing::warn!(
            target: "idfon.holder",
            peer_id = %peer,
            turn_id = %turn,
            error = %error,
            "cascade unit send failed"
        );
    }
}

#[allow(clippy::too_many_arguments)]
async fn send_snapshot(
    key: &SigningKey,
    transport: &IrohTransport,
    reply_ticket: Option<&CapabilityTicket>,
    peer: &str,
    route: &PeerRoute,
    turn_id: &str,
    step_index: u64,
    sequence: u64,
    snapshot: &str,
) -> Result<()> {
    let unit = CallTranscript::agent(turn_id, turn_id, snapshot, false);
    let text = encode_call_transcript(&unit)?;
    let endpoint_id = route
        .endpoint_id
        .parse()
        .map_err(|error| anyhow::anyhow!("invalid target endpoint ID: {error}"))?;
    let target_addr = EndpointAddr::new(endpoint_id);
    let ticket = ticket_for_target(peer, reply_ticket.cloned());
    let envelope = sign_message_with_ticket(
        key,
        peer_id(key),
        next_message_id("eve_unit_"),
        MessageContent::Text { text },
        format!("eve-unit-{turn_id}-{step_index}-{sequence}"),
        route.conversation.clone(),
        ticket,
    )?;
    transport.send(&target_addr, &envelope).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn push(
        peer: &str,
        turn: &str,
        step: u64,
        seq: u64,
        text: &str,
        at: Instant,
    ) -> Option<String> {
        push_at(peer, turn, step, seq, text, at).map(|(snapshot, _)| snapshot)
    }

    #[test]
    fn a_retry_never_snapshots_twice() {
        let t = Instant::now();
        assert_eq!(push("p-retry", "t", 0, 0, "Hello", t), Some("Hello".into()));
        assert_eq!(push("p-retry", "t", 0, 0, "Hello", t), None);
    }

    #[test]
    fn snapshots_are_cumulative_and_throttled() {
        let t = Instant::now();
        assert_eq!(push("p-throttle", "t", 0, 0, "One ", t), Some("One ".into()));
        // Inside the throttle window: no snapshot.
        assert_eq!(push("p-throttle", "t", 0, 1, "two.", t), None);
        // After it: the cumulative text so far.
        let late = t + MIN_INTERVAL;
        assert_eq!(
            push("p-throttle", "t", 0, 2, " Three.", late),
            Some("One two. Three.".into())
        );
    }

    #[test]
    fn envelope_markers_never_snapshot_even_when_split() {
        let t = Instant::now();
        assert!(push("p-envelope", "t", 0, 0, "Chart below.\n", t).is_some());
        let late = t + MIN_INTERVAL;
        assert_eq!(push("p-envelope", "t", 0, 1, "IDFON-ART", late), None);
        assert_eq!(push("p-envelope", "t", 0, 2, "IFACT/1\nid=x", late), None);
    }

    #[test]
    fn a_new_turn_resets_the_stream() {
        let t = Instant::now();
        assert!(push("p-newturn", "t1", 0, 0, "First.", t).is_some());
        let late = t + MIN_INTERVAL;
        assert_eq!(
            push("p-newturn", "t2", 0, 0, "Second.", late),
            Some("Second.".into())
        );
    }
}
