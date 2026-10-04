//! Composed holder binary: the generic idfon channel platform plus the
//! GPT-Live live-call handler. The platform crate itself knows no vendor; this
//! composition root is what opts the agent in.
//!
//! **GPT-Live-1 DEPRECATED (migration target).** Registering `GptLiveHandler`
//! here is why a call to *any* `eve-idfon-gpt` holder — including text-only
//! agents like `llm`/`agency` that have no `live.json` — is answered by
//! `openai/gpt-live-1` instead of the configured `EVE_IDFON_MODEL`. Live calls
//! must move to the `idfon-voice` cascade (STT → agent → TTS); see
//! `docs/voice-side-channel.md` ("Front-end resolved to cascade STT + TTS") and
//! `docs/live-voice.md` ("Decision"). Do not add new registrations.

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
