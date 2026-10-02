//! Barge-in semantics (F6): pre-playback steer vs post-playback cancel+queue,
//! and drop-by-counter so a steered follow-up is not discarded.
//!
//! `cancel({turnId})` keeps the same `turnId` for a subsequent `steer`, so the
//! delta drop must key on a **barge-in counter**, not the turn id
//! (`docs/voice-side-channel.md`, "Barge-in semantics"). What was heard before
//! a cancel is recorded as `playback.truncated{msg_id, heard_until}` through
//! the P0 recording mechanism.

/// What the client should do when the user barges in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BargeInAction {
    /// Before any playback: steer only; drop nothing, do not cancel.
    Steer,
    /// During playback: flush locally, `cancel(turnId)`, wait for
    /// `turn.cancelled`, then `send` with the default `queue`.
    CancelThenQueue,
}

/// What the user heard before playback was cancelled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaybackTruncated {
    pub msg_id: String,
    pub heard_until: String,
}

/// Counter-based barge-in state.
#[derive(Default)]
pub struct BargeInController {
    playing: bool,
    counter: u64,
    truncated: Vec<PlaybackTruncated>,
}

impl BargeInController {
    pub fn new() -> Self {
        Self::default()
    }

    /// Current counter: tag in-flight deltas with this value.
    pub fn counter(&self) -> u64 {
        self.counter
    }

    pub fn playback_started(&mut self) {
        self.playing = true;
    }

    pub fn playback_ended(&mut self) {
        self.playing = false;
    }

    pub fn is_playing(&self) -> bool {
        self.playing
    }

    /// The user barged in. A counter bump on cancel invalidates in-flight
    /// deltas; the steered follow-up is tagged with the new counter.
    pub fn barge_in(&mut self) -> BargeInAction {
        if !self.playing {
            return BargeInAction::Steer;
        }
        self.playing = false;
        self.counter += 1;
        BargeInAction::CancelThenQueue
    }

    /// Whether a delta tagged with `delta_counter` predates the last cancel and
    /// must be dropped. The steered follow-up (`delta_counter == counter`) is
    /// kept.
    pub fn should_drop(&self, delta_counter: u64) -> bool {
        delta_counter < self.counter
    }

    /// Record what was heard before a cancel. Idempotent per `msg_id`.
    pub fn record_truncation(&mut self, msg_id: impl Into<String>, heard_until: impl Into<String>) {
        let truncated = PlaybackTruncated {
            msg_id: msg_id.into(),
            heard_until: heard_until.into(),
        };
        if !self
            .truncated
            .iter()
            .any(|entry| entry.msg_id == truncated.msg_id)
        {
            self.truncated.push(truncated);
        }
    }

    pub fn truncations(&self) -> &[PlaybackTruncated] {
        &self.truncated
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pre_playback_steers_and_drops_nothing() {
        let mut controller = BargeInController::new();
        assert_eq!(controller.barge_in(), BargeInAction::Steer);
        assert_eq!(controller.counter(), 0);
        assert!(!controller.should_drop(0));
    }

    #[test]
    fn post_playback_cancel_drops_old_deltas_but_keeps_the_steered_follow_up() {
        let mut controller = BargeInController::new();
        controller.playback_started();
        // Deltas in flight for the current turn carry counter 0.
        assert!(!controller.should_drop(0));
        assert_eq!(controller.barge_in(), BargeInAction::CancelThenQueue);
        // The counter bumped: pre-cancel deltas drop, the steered follow-up
        // (same turnId, new counter) survives.
        assert!(controller.should_drop(0));
        assert!(!controller.should_drop(1));
    }

    #[test]
    fn truncation_is_recorded_once() {
        let mut controller = BargeInController::new();
        controller.playback_started();
        controller.barge_in();
        controller.record_truncation("msg-1", "Two plus two");
        controller.record_truncation("msg-1", "Two plus two");
        assert_eq!(
            controller.truncations(),
            &[PlaybackTruncated {
                msg_id: "msg-1".into(),
                heard_until: "Two plus two".into()
            }]
        );
    }
}
