//! Voice-agent runner: one binary hosting every linked backend.
//!
//! `--live-config` picks the backend (`backend` or `engine.kind`); adding an
//! engine is one `register(..)` line here, adding a voice agent is config.

use std::sync::Arc;

use anyhow::Result;
use eve_idfon::live::LiveCallRegistry;
use idfon_voice_agent::{CascadeFactory, VoiceAgentHandler};

#[tokio::main]
async fn main() -> Result<()> {
    let mut registry = LiveCallRegistry::new();
    registry.register(Arc::new(
        VoiceAgentHandler::new().with(Arc::new(CascadeFactory)),
    ));
    eve_idfon::run(registry).await
}
