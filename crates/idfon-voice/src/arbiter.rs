//! One-speaker arbitration and the F9 non-actor speech gate.
//!
//! Phase P5 (epic #17). One speaker at a time; the actor can preempt, non-actor
//! speech may not preempt the actor and never overlaps it. Non-actor speech
//! (director / voice-service / system) is limited to a **closed set of
//! non-substantive kinds**, length-capped (`docs/voice-side-channel.md`, F5/F9).

use std::collections::VecDeque;

/// Who is speaking.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SpeakerRole {
    Actor,
    Director,
    VoiceService,
    System,
}

impl SpeakerRole {
    pub fn is_actor(self) -> bool {
        self == Self::Actor
    }

    fn is_non_actor(self) -> bool {
        !self.is_actor()
    }
}

/// Closed set of non-substantive non-actor speech kinds (F9). No free text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NonSubstantiveKind {
    Acknowledgement,
    Status,
    SystemNotice,
}

impl NonSubstantiveKind {
    /// Length cap that keeps the kind non-substantive.
    pub fn max_chars(self) -> usize {
        match self {
            Self::Acknowledgement => 40,
            Self::Status => 120,
            Self::SystemNotice => 200,
        }
    }
}

/// Whether non-actor speech is allowed: a closed kind and within its cap.
pub fn non_actor_speech_allowed(kind: NonSubstantiveKind, text: &str) -> bool {
    text.chars().count() <= kind.max_chars()
}

/// What the arbiter decided for one speech request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArbiterOutcome {
    /// Granted; this role now holds the floor.
    Speak,
    /// Granted after taking the floor from a non-actor (actor-wins).
    Preempt,
    /// Held for later; the floor is still taken.
    Queued,
    /// Refused: substantive or kind-less non-actor speech.
    Rejected,
}

/// One-speaker arbiter with a wait queue and a tool-action window.
#[derive(Default)]
pub struct Arbiter {
    active: Option<SpeakerRole>,
    queue: VecDeque<SpeakerRole>,
    /// True between `actions.requested` and `action.result`; a barge-in must
    /// not cancel tool work (queued instead).
    tool_window: bool,
}

impl Arbiter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn active(&self) -> Option<SpeakerRole> {
        self.active
    }

    pub fn queued(&self) -> usize {
        self.queue.len()
    }

    pub fn set_tool_window(&mut self, active: bool) {
        self.tool_window = active;
    }

    pub fn in_tool_window(&self) -> bool {
        self.tool_window
    }

    /// Request the floor. Non-actor speech must name a [`NonSubstantiveKind`].
    pub fn request(
        &mut self,
        role: SpeakerRole,
        kind: Option<NonSubstantiveKind>,
    ) -> ArbiterOutcome {
        if role.is_non_actor() && kind.is_none() {
            return ArbiterOutcome::Rejected;
        }
        match self.active {
            None => {
                self.active = Some(role);
                ArbiterOutcome::Speak
            }
            Some(active) if active.is_non_actor() && role.is_actor() => {
                // Actor wins over a non-actor utterance; the non-actor yields.
                self.active = Some(role);
                ArbiterOutcome::Preempt
            }
            Some(_) => {
                // Never overlap; queue behind the current speaker.
                self.queue.push_back(role);
                ArbiterOutcome::Queued
            }
        }
    }

    /// The active speaker finished; grant the floor to the next queued role.
    pub fn finished(&mut self) -> Option<SpeakerRole> {
        self.active = self.queue.pop_front();
        self.active
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_actor_speech_requires_a_closed_kind() {
        let mut arbiter = Arbiter::new();
        assert_eq!(
            arbiter.request(SpeakerRole::Director, None),
            ArbiterOutcome::Rejected
        );
        assert_eq!(arbiter.active(), None, "rejected speech takes no floor");
        assert_eq!(
            arbiter.request(
                SpeakerRole::Director,
                Some(NonSubstantiveKind::Acknowledgement)
            ),
            ArbiterOutcome::Speak
        );
    }

    #[test]
    fn actor_preempts_non_actor_and_non_actor_never_overlaps_actor() {
        let mut arbiter = Arbiter::new();
        assert_eq!(
            arbiter.request(SpeakerRole::VoiceService, Some(NonSubstantiveKind::Status)),
            ArbiterOutcome::Speak
        );
        // Actor takes the floor from the non-actor.
        assert_eq!(
            arbiter.request(SpeakerRole::Actor, None),
            ArbiterOutcome::Preempt
        );
        assert_eq!(arbiter.active(), Some(SpeakerRole::Actor));
        // A non-actor cannot preempt the actor; it queues.
        assert_eq!(
            arbiter.request(SpeakerRole::Director, Some(NonSubstantiveKind::Status)),
            ArbiterOutcome::Queued
        );
        assert_eq!(arbiter.active(), Some(SpeakerRole::Actor));
        assert_eq!(arbiter.queued(), 1);
    }

    #[test]
    fn non_actor_length_cap_is_enforced() {
        assert!(non_actor_speech_allowed(
            NonSubstantiveKind::Acknowledgement,
            "okay"
        ));
        assert!(!non_actor_speech_allowed(
            NonSubstantiveKind::Acknowledgement,
            &"x".repeat(41)
        ));
    }
}
