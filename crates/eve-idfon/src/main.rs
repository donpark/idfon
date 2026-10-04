//! Generic idfon ingress-channel endpoint holder (no agent-specific behavior).
//!
//! Live-call handling is a capability-keyed handler seam (`eve_idfon::live`).
//! This binary registers none, so `IDFON-LIVE/1` controls fall through to the
//! agent as ordinary text. A build that wants live calls composes the platform
//! `run()` with a handler (see `crates/idfon-voice-agent`).

use anyhow::Result;
use eve_idfon::live::LiveCallRegistry;

#[tokio::main]
async fn main() -> Result<()> {
    eve_idfon::run(LiveCallRegistry::new()).await
}
