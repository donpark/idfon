//! Composed holder binary: the generic idfon channel platform plus the
//! cascade live-call handler. The counterpart to `eve-idfon-gpt`; the platform
//! crate itself knows no vendor, and this composition root opts the agent into
//! the streaming cascade instead of a full-duplex model.

use anyhow::Result;
use eve_idfon::live::LiveCallRegistry;
use idfon_live_cascade::CascadeLiveHandler;
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<()> {
    let mut registry = LiveCallRegistry::new();
    registry.register(Arc::new(CascadeLiveHandler));
    eve_idfon::run(registry).await
}
