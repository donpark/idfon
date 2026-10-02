//! Live-call handler seam.
//!
//! The generic holder parses `IDFON-LIVE/1` controls and dispatches them to a
//! handler registered against the capability the control needs
//! (`live.audio.publish` / `live.video.publish`). The platform owns the wire
//! contract and lifecycle plumbing; the handler owns the vendor session
//! behind it.
//!
//! Agent-specific configuration is opaque JSON here: it arrives from the
//! channel config (`serve --live-config FILE`) or a ticket metadata field and
//! is handed to the handler untouched, so this crate names no vendor.

use std::{collections::HashMap, sync::Arc};

use anyhow::Result;
use ed25519_dalek::SigningKey;
use futures_util::future::BoxFuture;
use idfon_core::transport::IrohTransport;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::{records, rooms, IpcFrame, Targets};

/// Capability a live audio control needs.
pub const AUDIO_PUBLISH: &str = "live.audio.publish";
/// Capability a live video control needs.
pub const VIDEO_PUBLISH: &str = "live.video.publish";

/// The capability a live control declares, or `None` for non-live text.
/// Unknown kinds default to audio, matching the invite contract.
pub fn capability_for_control(text: &str) -> Option<&'static str> {
    let body = text.strip_prefix("IDFON-LIVE/1\n")?;
    let kind = body
        .lines()
        .find_map(|line| line.strip_prefix("kind="))
        .unwrap_or("audio");
    Some(match kind {
        "video" => VIDEO_PUBLISH,
        _ => AUDIO_PUBLISH,
    })
}

/// Platform services handed to a live-call handler. Deliberately concrete: the
/// handler is linked into the same process as the holder and reuses its
/// transport, reply targets, records, and IPC.
pub struct LiveCallContext {
    pub text: String,
    pub sender_peer_id: String,
    pub sender_endpoint_id: String,
    pub conversation: Option<String>,
    pub holder_endpoint_id: String,
    pub transport: Arc<IrohTransport>,
    pub key: SigningKey,
    pub targets: Targets,
    pub out_tx: mpsc::Sender<IpcFrame>,
    /// Opaque agent/channel configuration for this handler.
    pub params: Value,
}

impl LiveCallContext {
    /// Voice is 1:1 only: a room never opens a live session.
    pub fn is_room(&self) -> bool {
        rooms::registry().is_room(self.conversation.as_deref())
    }

    /// Append a durable voice record for the caller (P0 transcript buffer).
    pub fn append_record(&self, record: records::VoiceRecord) {
        records::store().append(&self.sender_peer_id, record);
    }
}

pub type LiveCallFuture = BoxFuture<'static, Result<bool>>;

/// One live-call implementation, registered against the capabilities it serves.
pub trait LiveCallHandler: Send + Sync {
    fn capabilities(&self) -> &'static [&'static str];
    /// Returns `Ok(true)` when the control was consumed, `Ok(false)` to let it
    /// fall through to the agent as ordinary text.
    fn handle(&self, ctx: LiveCallContext) -> LiveCallFuture;
}

/// Capability-keyed handler table built by the composition root (the binary).
#[derive(Default, Clone)]
pub struct LiveCallRegistry {
    handlers: HashMap<&'static str, Arc<dyn LiveCallHandler>>,
}

impl LiveCallRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, handler: Arc<dyn LiveCallHandler>) {
        for capability in handler.capabilities() {
            self.handlers.insert(capability, Arc::clone(&handler));
        }
    }

    pub fn get(&self, capability: &str) -> Option<&Arc<dyn LiveCallHandler>> {
        self.handlers.get(capability)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_capability_maps_kind_and_rejects_text() {
        assert_eq!(
            capability_for_control("IDFON-LIVE/1\naction=start\nticket=t"),
            Some(AUDIO_PUBLISH)
        );
        assert_eq!(
            capability_for_control("IDFON-LIVE/1\naction=start\nkind=video\nticket=t"),
            Some(VIDEO_PUBLISH)
        );
        assert_eq!(capability_for_control("hello"), None);
        assert_eq!(capability_for_control("IDFON-CALL/1\n{}"), None);
    }

    struct Fake(&'static [&'static str]);

    impl LiveCallHandler for Fake {
        fn capabilities(&self) -> &'static [&'static str] {
            self.0
        }
        fn handle(&self, _ctx: LiveCallContext) -> LiveCallFuture {
            Box::pin(async { Ok(true) })
        }
    }

    #[test]
    fn registry_is_keyed_by_capability() {
        let mut registry = LiveCallRegistry::new();
        registry.register(Arc::new(Fake(&[AUDIO_PUBLISH])));
        assert!(registry.get(AUDIO_PUBLISH).is_some());
        assert!(registry.get(VIDEO_PUBLISH).is_none());
    }
}
