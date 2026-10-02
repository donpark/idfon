//! Speaker labels and the holder's append-only audit log.
//!
//! Every utterance carries a **required, fixed-enum** speaker label so no
//! consumer sees agent-authored text it did not write, and a transcript cannot
//! forge a label (`docs/voice-side-channel.md`, "Signing and principal"). The
//! holder signs the label when it emits a wire envelope; this module owns the
//! closed vocabulary and the append-only audit copy (Eve history is the model's
//! view of it).

use std::sync::Mutex;

/// Closed speaker vocabulary for voice-side-channel utterances.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Speaker {
    /// The person on the call.
    Caller,
    /// The actor agent's own text.
    Agent,
    /// Non-substantive director speech (F9).
    Director,
    /// Voice-service speech (status/notice).
    VoiceService,
    /// System notices.
    System,
}

impl Speaker {
    /// Canonical lowercase token used on the wire and in the audit log.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Caller => "caller",
            Self::Agent => "agent",
            Self::Director => "director",
            Self::VoiceService => "voice-service",
            Self::System => "system",
        }
    }
}

/// One recorded utterance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Utterance {
    pub utterance_id: String,
    pub speaker: Speaker,
    pub text: String,
    pub at_ms: u64,
}

/// Append-only audit copy held at the holder.
#[derive(Default)]
pub struct AuditLog {
    entries: Mutex<Vec<Utterance>>,
}

impl AuditLog {
    pub fn record(&self, utterance: Utterance) {
        self.entries
            .lock()
            .expect("audit log poisoned")
            .push(utterance);
    }

    pub fn entries(&self) -> Vec<Utterance> {
        self.entries.lock().expect("audit log poisoned").clone()
    }

    pub fn len(&self) -> usize {
        self.entries.lock().expect("audit log poisoned").len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speakers_are_a_closed_fixed_vocabulary() {
        let labels = [
            Speaker::Caller,
            Speaker::Agent,
            Speaker::Director,
            Speaker::VoiceService,
            Speaker::System,
        ];
        let tokens: Vec<_> = labels.iter().map(|speaker| speaker.as_str()).collect();
        assert_eq!(
            tokens,
            ["caller", "agent", "director", "voice-service", "system"]
        );
        // Distinct tokens (no label collision / forgery).
        assert_eq!(
            tokens
                .iter()
                .collect::<std::collections::HashSet<_>>()
                .len(),
            tokens.len()
        );
    }

    #[test]
    fn audit_log_is_append_only_and_ordered() {
        let log = AuditLog::default();
        assert!(log.is_empty());
        log.record(Utterance {
            utterance_id: "u1".into(),
            speaker: Speaker::Caller,
            text: "hello".into(),
            at_ms: 1,
        });
        log.record(Utterance {
            utterance_id: "u2".into(),
            speaker: Speaker::Agent,
            text: "hi".into(),
            at_ms: 2,
        });
        let entries = log.entries();
        assert_eq!(log.len(), 2);
        assert_eq!(entries[0].speaker, Speaker::Caller);
        assert_eq!(entries[1].speaker, Speaker::Agent);
    }
}
