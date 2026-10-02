//! Turn-level `speak`: the voice service renders one completed agent turn.
//!
//! Phase P3 (epic #17). This is the minimum that makes "the service speaks
//! completed turns" real: authorize the caller, resolve the voice through the
//! registry (F8), synthesize (F1), and record an `Agent`-labelled utterance in
//! the holder's append-only audit log. Streaming/clause batching is P4; the
//! director owns focus/modality and is not consulted here (the actor's explicit
//! `speak()` wins).

use crate::{
    AudioFormat, AuditLog, ModelRegistry, PcmChunk, SpeakAuthorizer, SpeakDenied, SpeakPolicy,
    Speaker, Utterance, VoiceEngine,
};
use idfon_protocol::Capability;

/// A synthesized completed turn, ready to enqueue for playback.
#[derive(Debug, Clone)]
pub struct SpokenTurn {
    /// Resolved canonical `engine:model:voice` id.
    pub voice: String,
    /// Audio chunks in the requested format (stub: silence).
    pub chunks: Vec<PcmChunk>,
    /// The audit record written for this utterance.
    pub utterance: Utterance,
}

/// Why a turn was not spoken.
#[derive(Debug)]
pub enum SpeakError {
    Denied(SpeakDenied),
    UnknownVoice(String),
    Engine(anyhow::Error),
}

impl std::fmt::Display for SpeakError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Denied(denied) => write!(formatter, "speak denied: {denied:?}"),
            Self::UnknownVoice(voice) => write!(formatter, "unknown voice: {voice}"),
            Self::Engine(error) => write!(formatter, "tts engine: {error}"),
        }
    }
}

impl std::error::Error for SpeakError {}

/// The turn-level voice service: one engine, one registry, one authorizer, one
/// audit log. `Send + Sync` so it can be shared at the holder edge.
pub struct VoiceService {
    engine: Box<dyn VoiceEngine>,
    registry: ModelRegistry,
    authorizer: SpeakAuthorizer,
    audit: AuditLog,
    format: AudioFormat,
}

impl VoiceService {
    pub fn new(
        engine: Box<dyn VoiceEngine>,
        registry: ModelRegistry,
        policy: SpeakPolicy,
        format: AudioFormat,
    ) -> Self {
        Self {
            engine,
            registry,
            authorizer: SpeakAuthorizer::new(policy),
            audit: AuditLog::default(),
            format,
        }
    }

    pub fn engine_name(&self) -> &str {
        self.engine.name()
    }

    pub fn registry(&self) -> &ModelRegistry {
        &self.registry
    }

    pub fn audit(&self) -> &AuditLog {
        &self.audit
    }

    /// Speak one completed actor turn. Requires the scoped `voice.speak` grant
    /// (N9); denied/unknown-voice requests record nothing.
    pub fn speak_turn(
        &self,
        capabilities: &[Capability],
        turn_id: &str,
        text: &str,
        voice: &str,
        at_ms: u64,
    ) -> Result<SpokenTurn, SpeakError> {
        self.authorizer
            .authorize(capabilities, text)
            .map_err(SpeakError::Denied)?;
        let model = self
            .registry
            .resolve(voice)
            .ok_or_else(|| SpeakError::UnknownVoice(voice.to_string()))?;
        let mut tts = self
            .engine
            .tts(&model.voice, self.format)
            .map_err(SpeakError::Engine)?;
        // G2P front end: speak written numbers as words; audit keeps the
        // original agent text.
        let spoken = crate::g2p::normalize_for_speech(text);
        let mut chunks = tts.push_text(&spoken).map_err(SpeakError::Engine)?;
        chunks.extend(tts.finish().map_err(SpeakError::Engine)?);

        let utterance = Utterance {
            utterance_id: format!("{turn_id}:agent"),
            speaker: Speaker::Agent,
            text: text.to_string(),
            at_ms,
        };
        self.audit.record(utterance.clone());
        Ok(SpokenTurn {
            voice: model.id(),
            chunks,
            utterance,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::StubVoiceEngine;

    fn service() -> VoiceService {
        VoiceService::new(
            Box::new(StubVoiceEngine::new()),
            ModelRegistry::bundled(),
            SpeakPolicy::default(),
            AudioFormat::PCM_24K_MONO,
        )
    }

    #[test]
    fn authorized_turn_speaks_and_records_an_agent_utterance() {
        let service = service();
        let spoken = service
            .speak_turn(
                &[Capability::VoiceSpeak],
                "turn-1",
                "Two plus two is four.",
                "default",
                42,
            )
            .expect("speak");

        assert!(spoken.voice.starts_with("stub:"));
        assert!(!spoken.chunks.is_empty());
        assert_eq!(spoken.utterance.speaker, Speaker::Agent);
        assert_eq!(spoken.utterance.utterance_id, "turn-1:agent");
        assert_eq!(service.audit().len(), 1);
        assert_eq!(service.audit().entries()[0].text, "Two plus two is four.");
    }

    #[test]
    fn denied_and_unknown_voice_turns_record_nothing() {
        let service = service();
        assert!(matches!(
            service.speak_turn(&[], "turn-1", "hello", "default", 0),
            Err(SpeakError::Denied(SpeakDenied::MissingGrant))
        ));
        assert!(matches!(
            service.speak_turn(
                &[Capability::VoiceSpeak],
                "turn-2",
                "hello",
                "no-such-voice",
                0
            ),
            Err(SpeakError::UnknownVoice(_))
        ));
        assert!(service.audit().is_empty());
    }
}
