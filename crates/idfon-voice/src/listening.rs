//! P7 listening-test gate and BWE decision.
//!
//! Phase P7 (epic #17). Two things are decision-shaped rather than
//! implementation-shaped: whether the bundled default voice is good enough
//! (the human listening test) and whether to spend on bandwidth extension
//! (BWE). This module holds the recorded test result, the pass bar, and the
//! deterministic gate so the decision is auditable instead of prose.
//!
//! `docs/voice-side-channel.md` keeps the engine decision (stay cascade
//! STT/TTS; no full-duplex) and the deferred LLM/AFM director.

/// Result of the human listening test for a candidate voice.
#[derive(Debug, Clone, PartialEq)]
pub struct ListeningTest {
    /// High-frequency energy deficit of the default voice vs the reference,
    /// in dB (higher = more missing top end).
    pub hf_deficit_db: f64,
    /// Word-level intelligibility, 0..=1.
    pub intelligibility: f64,
    /// Free-text notes from the listener (recorded, not gated on).
    pub notes: String,
}

/// Acceptance bar the test must clear. These are the recorded thresholds.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PassBar {
    pub max_hf_deficit_db: f64,
    pub min_intelligibility: f64,
}

impl Default for PassBar {
    fn default() -> Self {
        Self {
            // ponytail: initial bar; adjust when the test is actually run.
            max_hf_deficit_db: 3.0,
            min_intelligibility: 0.95,
        }
    }
}

/// Whether the voice passes the bar without any BWE.
pub fn passes(test: &ListeningTest, bar: PassBar) -> bool {
    test.hf_deficit_db <= bar.max_hf_deficit_db && test.intelligibility >= bar.min_intelligibility
}

/// BWE is justified only when the test shows a real high-frequency deficit
/// beyond the bar. Intelligibility alone does not buy BWE.
pub fn bwe_justified(test: &ListeningTest, bar: PassBar) -> bool {
    test.hf_deficit_db > bar.max_hf_deficit_db
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test(hf_deficit_db: f64, intelligibility: f64) -> ListeningTest {
        ListeningTest {
            hf_deficit_db,
            intelligibility,
            notes: String::new(),
        }
    }

    #[test]
    fn pass_bar_requires_both_hf_and_intelligibility() {
        let bar = PassBar::default();
        assert!(passes(&test(1.0, 0.98), bar));
        assert!(!passes(&test(4.0, 0.98), bar), "too much HF deficit");
        assert!(!passes(&test(1.0, 0.90), bar), "too little intelligibility");
    }

    #[test]
    fn bwe_is_only_justified_by_a_real_hf_deficit() {
        let bar = PassBar::default();
        assert!(!bwe_justified(&test(1.0, 0.99), bar));
        assert!(bwe_justified(&test(6.0, 0.99), bar));
        // Low intelligibility with fine HF does not trigger BWE.
        assert!(!bwe_justified(&test(1.0, 0.5), bar));
    }
}
