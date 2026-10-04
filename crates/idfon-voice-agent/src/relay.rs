//! Relay backend: hand caller audio to a standalone TypeScript voice agent and
//! play back what it returns. No STT/TTS here — the agent owns them.
//!
//! Outbound: each caller frame goes to the bridge (SSE subscribers). Inbound:
//! PCM the agent posts to `/live/audio` arrives on `eve_idfon::live_audio` and
//! is published on the return leg.

use std::sync::atomic::Ordering;
use std::time::Duration;

use anyhow::Result;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::{BackendFuture, VoiceBackend, VoiceBackendFactory, VoiceMedia};

pub struct RelayBackend;

impl VoiceBackend for RelayBackend {
    fn name(&self) -> &str {
        "relay"
    }

    fn run(&mut self, media: VoiceMedia) -> BackendFuture<'_> {
        Box::pin(self.run_loop(media))
    }
}

impl RelayBackend {
    async fn run_loop(&mut self, mut media: VoiceMedia) -> Result<()> {
        let peer = media.bridge.peer_id().to_string();
        let (tx, mut rx) = mpsc::unbounded_channel();
        eve_idfon::live_audio::register(&peer, tx);
        let mut tick = tokio::time::interval(Duration::from_millis(200));
        loop {
            tokio::select! {
                item = media.caller.recv() => {
                    let Some(pcm) = item else { break };
                    media.bridge.send_frame(&pcm).await;
                }
                Some(samples) = rx.recv() => {
                    media.audio.push_samples(&samples);
                }
                _ = tick.tick() => {
                    if media.stop.load(Ordering::Relaxed) { break; }
                }
            }
        }
        eve_idfon::live_audio::unregister(&peer);
        Ok(())
    }
}

/// Builds the relay backend (the standalone TS agent owns STT/TTS).
pub struct RelayFactory;

impl VoiceBackendFactory for RelayFactory {
    fn kind(&self) -> &str {
        "relay"
    }

    fn create(&self, _params: &Value) -> Result<Box<dyn VoiceBackend>> {
        Ok(Box::new(RelayBackend))
    }
}
