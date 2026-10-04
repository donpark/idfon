//! Appended call audio: agent-produced PCM for the active call's return leg.
//!
//! A voice agent that terminates a live call in TypeScript produces speech in
//! the agent process; it posts the PCM to the bridge, which forwards it here.
//! The call's backend registers a sink per peer and publishes what arrives.
//! This is the *outbound* (agent → caller) half; caller audio reaches the agent
//! through the turn/blob path.

use std::{collections::HashMap, sync::Mutex, sync::OnceLock};

use tokio::sync::mpsc::UnboundedSender;

type Sink = UnboundedSender<Vec<i16>>;

static SINKS: OnceLock<Mutex<HashMap<String, Sink>>> = OnceLock::new();

fn sinks() -> &'static Mutex<HashMap<String, Sink>> {
    SINKS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Register the return-leg sink for a peer (one active call per holder).
pub fn register(peer_id: &str, sink: Sink) {
    if let Ok(mut sinks) = sinks().lock() {
        sinks.insert(peer_id.to_string(), sink);
    }
}

/// Drop a peer's sink.
pub fn unregister(peer_id: &str) {
    if let Ok(mut sinks) = sinks().lock() {
        sinks.remove(peer_id);
    }
}

/// Push one chunk of agent PCM to the peer's return leg. Returns false when no
/// call is listening.
pub fn append(peer_id: &str, samples: Vec<i16>) -> bool {
    let sink = sinks()
        .lock()
        .ok()
        .and_then(|sinks| sinks.get(peer_id).cloned());
    sink.map(|sink| sink.send(samples).is_ok()).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_only_for_registered_peers() {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        register("peer-a", tx);
        assert!(append("peer-a", vec![1, 2, 3]));
        assert_eq!(rx.try_recv().unwrap(), vec![1, 2, 3]);
        assert!(!append("peer-b", vec![4]));
        unregister("peer-a");
        assert!(!append("peer-a", vec![5]));
    }
}
