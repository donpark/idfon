//! Composed holder binary: the generic idfon channel platform plus the
//! GPT-Live live-call handler. The platform crate itself knows no vendor; this
//! composition root is what opts the agent in.
//!
//! This registers the GPT-Live full-duplex backend. It is one supported model,
//! not a special path — a holder only routes live controls to it when it
//! advertises `native-duplex` (the holder gate in `eve-idfon`). New voice
//! agents should use the config-driven voice-agent runner (`eve-idfon-voice`,
//! `crates/idfon-voice-agent`); see `docs/voice-agent.md`.

use anyhow::Result;
use eve_idfon::live::LiveCallRegistry;
use idfon_live_gpt::GptLiveHandler;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<()> {
    let mut registry = LiveCallRegistry::new();
    registry.register(Arc::new(GptLiveHandler));
    eve_idfon::run(registry).await
}
