//! Deterministic policy director (P3): focus, modality defaults, and timing
//! with **no generation**. The LLM/AFM director is deferred until voice-in-rooms
//! is designed (`docs/voice-side-channel.md`, "Policy director").
//!
//! The directive set is closed — no free-text fields — so a directive can only
//! control, never author speech (F9). Precedence: an explicit `speak()` wins
//! over `suppress`/`defer`.

use std::collections::{HashMap, HashSet};

/// A control directive. Speech is not a directive.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Directive {
    /// Deliver one turn to one session (1:1 focus by default).
    Route {
        turn_id: String,
        session: String,
    },
    SetFocus {
        session: String,
    },
    Present {
        msg_id: String,
    },
    Suppress {
        msg_id: String,
    },
    Preempt {
        utterance_id: String,
    },
    Defer {
        msg_id: String,
        until_ms: u64,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DirectorError {
    /// `route` target is not one of the principal's sessions.
    ForeignRoute { session: String },
}

/// Stateful director with an append-only directive log (auditable).
pub struct DeterministicDirector {
    focus: Option<String>,
    suppressed: HashSet<String>,
    deferred: HashMap<String, u64>,
    log: Vec<Directive>,
}

impl Default for DeterministicDirector {
    fn default() -> Self {
        Self::new()
    }
}

impl DeterministicDirector {
    pub fn new() -> Self {
        Self {
            focus: None,
            suppressed: HashSet::new(),
            deferred: HashMap::new(),
            log: Vec::new(),
        }
    }

    pub fn focus(&self) -> Option<&str> {
        self.focus.as_deref()
    }

    pub fn set_focus(&mut self, session: impl Into<String>) {
        let session = session.into();
        self.focus = Some(session.clone());
        self.log.push(Directive::SetFocus { session });
    }

    /// Route a turn, validating that the target belongs to the same principal.
    pub fn route(
        &mut self,
        turn_id: impl Into<String>,
        session: impl Into<String>,
        principal_sessions: &HashSet<String>,
    ) -> Result<(), DirectorError> {
        let session = session.into();
        if !principal_sessions.contains(&session) {
            return Err(DirectorError::ForeignRoute { session });
        }
        self.log.push(Directive::Route {
            turn_id: turn_id.into(),
            session,
        });
        Ok(())
    }

    pub fn present(&mut self, msg_id: impl Into<String>) {
        self.log.push(Directive::Present {
            msg_id: msg_id.into(),
        });
    }

    pub fn suppress(&mut self, msg_id: impl Into<String>) {
        let msg_id = msg_id.into();
        self.suppressed.insert(msg_id.clone());
        self.log.push(Directive::Suppress { msg_id });
    }

    pub fn preempt(&mut self, utterance_id: impl Into<String>) {
        self.log.push(Directive::Preempt {
            utterance_id: utterance_id.into(),
        });
    }

    pub fn defer(&mut self, msg_id: impl Into<String>, until_ms: u64) {
        let msg_id = msg_id.into();
        self.deferred.insert(msg_id.clone(), until_ms);
        self.log.push(Directive::Defer { msg_id, until_ms });
    }

    /// Whether a message should be spoken now. An explicit actor `speak()` is
    /// authoritative and cannot be suppressed or deferred (F9 actor-wins).
    pub fn should_speak(&self, msg_id: &str, explicit: bool, now_ms: u64) -> bool {
        if explicit {
            return true;
        }
        if self.suppressed.contains(msg_id) {
            return false;
        }
        if let Some(until) = self.deferred.get(msg_id) {
            if now_ms < *until {
                return false;
            }
        }
        true
    }

    /// Append-only directive log.
    pub fn directives(&self) -> &[Directive] {
        &self.log
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sessions() -> HashSet<String> {
        ["peer-a".to_string(), "peer-a:thread-1".to_string()].into()
    }

    #[test]
    fn explicit_speak_wins_over_suppress_and_defer() {
        let mut director = DeterministicDirector::new();
        director.suppress("msg-1");
        director.defer("msg-1", 10_000);

        assert!(!director.should_speak("msg-1", false, 0));
        // Explicit speak overrides both.
        assert!(director.should_speak("msg-1", true, 0));

        // Defer expires at its deadline for non-explicit speech.
        let mut director = DeterministicDirector::new();
        director.defer("msg-2", 5_000);
        assert!(!director.should_speak("msg-2", false, 4_999));
        assert!(director.should_speak("msg-2", false, 5_000));
    }

    #[test]
    fn route_must_target_the_principal_and_focus_is_tracked() {
        let mut director = DeterministicDirector::new();
        assert!(director.route("turn-1", "peer-a", &sessions()).is_ok());
        assert_eq!(
            director.route("turn-2", "peer-b", &sessions()),
            Err(DirectorError::ForeignRoute {
                session: "peer-b".into()
            })
        );

        director.set_focus("peer-a");
        assert_eq!(director.focus(), Some("peer-a"));

        // The directive log is append-only and ordered.
        assert_eq!(
            director.directives(),
            &[
                Directive::Route {
                    turn_id: "turn-1".into(),
                    session: "peer-a".into()
                },
                Directive::SetFocus {
                    session: "peer-a".into()
                },
            ]
        );
    }
}
