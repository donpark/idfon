//! Cascade live-call handler for the idfon channel holder (scaffold).
//!
//! Counterpart to `idfon-live-gpt`: that crate runs one full-duplex model
//! (`openai/gpt-live-1`); this one is the streaming **cascade** behind the text
//! boundary — caller audio → STT → an ordinary agent text turn → TTS → return
//! audio (`docs/voice-side-channel.md`). It reuses `idfon-voice` for the engine
//! seam, streaming speaker, arbiter, barge-in, and echo suppression.
//!
//! **Status: scaffold.** [`CascadeLiveHandler::handle`] declines, so a live
//! control falls through to an ordinary text turn (the client-side A1 cascade
//! then drives the agent). Wire the pipeline per the TODOs below; the
//! composition root (`src/main.rs`) already registers it.

use eve_idfon::live::{LiveCallContext, LiveCallFuture, LiveCallHandler, AUDIO_PUBLISH};

/// Streaming cascade live-call handler.
pub struct CascadeLiveHandler;

impl LiveCallHandler for CascadeLiveHandler {
    fn capabilities(&self) -> &'static [&'static str] {
        &[AUDIO_PUBLISH]
    }

    fn handle(&self, ctx: LiveCallContext) -> LiveCallFuture {
        Box::pin(async move {
            // TODO(cascade live calls) — port the media plumbing from
            // `idfon-live-gpt` (start-invite parse, caller subscribe, return-leg
            // publish, hangup) and replace its model session with the cascade:
            //
            // 1. Subscribe the caller's audio and decode to PCM, then feed
            //    `idfon_voice::listen::ListenSession` (STT) instead of a model.
            // 2. On each final transcript, run a normal agent turn through the
            //    bridge (`turn.in` → `/reply`) with the caller's identity — the
            //    same path a chat message uses.
            // 3. Feed the agent reply text to
            //    `idfon_voice::stream::StreamingSpeaker` (clause-batched TTS) and
            //    publish the return leg; run `idfon_voice`'s
            //    arbiter/barge-in/echo filters over the caller's live STT.
            // 4. Record every utterance with `ctx.append_record(..)` (P0 buffer).
            //
            // Until then, decline so the control becomes an ordinary text turn.
            eprintln!(
                "[eve-idfon] cascade live handler is a scaffold; declining live control from {}",
                ctx.sender_peer_id
            );
            Ok(false)
        })
    }
}
