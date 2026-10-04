//! Agent-output delta routing (F11).
//!
//! The Eve channel forwards `message.appended` deltas over the bridge to
//! `IpcFrame::StreamAppend`. A live voice backend (the cascade) wants those
//! deltas so TTS starts at the first clause instead of waiting for the whole
//! reply. This registry lets a backend subscribe per peer: the generic holder
//! routes a delta to the sink registered for its peer, or drops it as before.

use std::{collections::HashMap, sync::Mutex, sync::OnceLock};

use tokio::sync::mpsc::UnboundedSender;

/// One agent-output delta: `(turn_id, step_index, sequence, text)`.
pub type Delta = (String, u64, u64, String);

type Sink = UnboundedSender<Delta>;

static SINKS: OnceLock<Mutex<HashMap<String, Sink>>> = OnceLock::new();

fn sinks() -> &'static Mutex<HashMap<String, Sink>> {
    SINKS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Register the sink for a peer (one active call per holder).
pub fn register(peer_id: &str, sink: Sink) {
    if let Ok(mut sinks) = sinks().lock() {
        sinks.insert(peer_id.to_string(), sink);
    }
}

/// Drop a peer's sink. The receiver going away is also enough for `route` to
/// fail; this is just cleanup.
pub fn unregister(peer_id: &str) {
    if let Ok(mut sinks) = sinks().lock() {
        sinks.remove(peer_id);
    }
}

/// Route one delta to the peer's sink. Returns false when nobody is listening
/// (no active call, or the call's receiver dropped).
pub fn route(peer_id: &str, delta: Delta) -> bool {
    let sink = sinks()
        .lock()
        .ok()
        .and_then(|sinks| sinks.get(peer_id).cloned());
    sink.map(|sink| sink.send(delta).is_ok()).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_only_for_registered_peers() {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        register("peer-a", tx);
        assert!(route("peer-a", ("t".into(), 0, 0, "hi".into())));
        assert_eq!(rx.try_recv().unwrap().3, "hi");
        assert!(!route("peer-b", ("t".into(), 0, 1, "yo".into())));
        unregister("peer-a");
        assert!(!route("peer-a", ("t".into(), 0, 2, "gone".into())));
    }
}
