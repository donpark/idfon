//! Voice-agent runner: one binary hosting every linked backend.
//!
//! `--live-config` picks the backend (`backend` or `engine.kind`); adding an
//! engine is one `register(..)` line here, adding a voice agent is config.

use std::sync::Arc;

use anyhow::Result;
use eve_idfon::live::LiveCallRegistry;
use idfon_voice_agent::{CascadeFactory, RelayFactory, VoiceAgentHandler};
#[cfg(feature = "gpt-live")]
use idfon_voice_agent::GptLiveFactory;

#[tokio::main]
async fn main() -> Result<()> {
    let mut registry = LiveCallRegistry::new();
    let handler = VoiceAgentHandler::new()
        .with(Arc::new(CascadeFactory))
        .with(Arc::new(RelayFactory));
    #[cfg(feature = "gpt-live")]
    let handler = handler.with(Arc::new(GptLiveFactory));
    registry.register(Arc::new(handler));
    eve_idfon::run(registry).await
}
