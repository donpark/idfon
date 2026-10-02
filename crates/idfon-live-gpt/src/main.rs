//! Composed holder binary: the generic idfon channel platform plus the
//! GPT-Live live-call handler. The platform crate itself knows no vendor; this
//! composition root is what opts the agent in.

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
