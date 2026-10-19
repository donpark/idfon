//! Adaptive calibration: observe outcome labels, nudge the trait at call start.
//! Ported from the relay's `adapt` closure (integrations/eve-idfon-voice/tyger-relay.mjs
//! lines 83-137) — the tier-neutral half of docs/voice-decisions.md's calibration
//! contract: the trait is the prior; per-user drift is clamped to ±[`ADAPT_MAX`] with
//! at most one [`ADAPT_STEP`] per knob per call; applied at call start only, never
//! mid-call; the user can pin or reset by editing/clearing the state file.
//!
//! State file is JSON `{counts, delta}` — the same shape the JS relay reads/writes
//! (`updated` is JS-side bookkeeping and is ignored here). Until the switch-over the
//! JS relay stays authoritative; a decision-log diff validates the swapped-in port.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub const ADAPT_MAX: f64 = 0.15;
pub const ADAPT_STEP: f64 = 0.02;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct AdaptState {
    #[serde(default)]
    pub counts: BTreeMap<String, u64>,
    #[serde(default)]
    pub delta: BTreeMap<String, f64>,
}

/// JS `+(x).toFixed(4)`: round to 4 decimals, ties toward +∞.
fn to_fixed_4(x: f64) -> f64 {
    (x * 10_000.0 + 0.5).floor() / 10_000.0
}

impl AdaptState {
    pub fn load(path: &std::path::Path) -> AdaptState {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, path: &std::path::Path) {
        if let Ok(s) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, s);
        }
    }

    /// One observed outcome (always recorded; counts persist only with a state file).
    pub fn bump(&mut self, name: &str) {
        *self.counts.entry(name.to_string()).or_insert(0) += 1;
    }

    fn more(&self, a: &str, b: &str) -> bool {
        self.counts.get(a).copied().unwrap_or(0) > self.counts.get(b).copied().unwrap_or(0)
    }

    fn step(&mut self, k: &str, dir: f64) {
        let d = self.delta.entry(k.to_string()).or_insert(0.0);
        *d = (*d + dir * ADAPT_STEP).clamp(-ADAPT_MAX, ADAPT_MAX);
    }

    /// Effective decider params: trait prior + bounded drift toward what this user's
    /// behavior asks for. One call-start: each knob moves at most one step.
    pub fn thresholds(&mut self, base: &BTreeMap<String, f64>) -> BTreeMap<String, f64> {
        if self.more("early_cut_in", "late_endpoint") {
            self.step("ep_thr", 1.0);
        } // cut off too often: wait more
        if self.more("late_endpoint", "early_cut_in") {
            self.step("ep_thr", -1.0);
        } // dead air: answer sooner
        if self.more("missed_barge", "real_barge") {
            self.step("barge_thr", -1.0);
        } // they interrupt: yield faster
        if self.more("false_barge", "real_barge") {
            self.step("barge_thr", 1.0);
        } // noise was not a grab: hold
        if self.more("bc_intrusive", "bc_ok") {
            self.step("bc_thr", 1.0);
        } // mm-hm stops them: fewer
        if self.more("bc_ok", "bc_intrusive") {
            self.step("bc_thr", -1.0);
        } // they like it: more
        let mut out = base.clone();
        for (k, v) in &self.delta {
            if *v != 0.0 {
                if let Some(x) = out.get_mut(k) {
                    *x = to_fixed_4(*x + *v);
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> BTreeMap<String, f64> {
        [("ep_thr", 0.9146), ("barge_thr", 0.5), ("bc_thr", 0.5)]
            .iter()
            .map(|(k, v)| (k.to_string(), *v))
            .collect()
    }

    #[test]
    fn direction_table() {
        // each pair's dominance moves its knob exactly one step, in the coded direction
        for (outcome, knob, dir) in [
            ("early_cut_in", "ep_thr", 1.0),
            ("late_endpoint", "ep_thr", -1.0),
            ("missed_barge", "barge_thr", -1.0),
            ("false_barge", "barge_thr", 1.0),
            ("bc_intrusive", "bc_thr", 1.0),
            ("bc_ok", "bc_thr", -1.0),
        ] {
            let mut st = AdaptState::default();
            st.bump(outcome);
            let out = st.thresholds(&base());
            assert_eq!(st.delta[knob], dir * ADAPT_STEP, "{outcome}");
            assert_eq!(out[knob], to_fixed_4(base()[knob] + dir * ADAPT_STEP), "{outcome}");
        }
    }

    #[test]
    fn strictly_more_and_one_step_per_call() {
        let mut st = AdaptState::default();
        st.bump("early_cut_in");
        st.bump("late_endpoint"); // tied: nothing moves
        st.thresholds(&base());
        assert!(st.delta.is_empty());
        st.bump("early_cut_in"); // now strictly more
        st.thresholds(&base());
        st.thresholds(&base()); // a second call-start is a second step: cumulative
        assert_eq!(st.delta["ep_thr"], 2.0 * ADAPT_STEP);
    }

    #[test]
    fn clamp_at_max() {
        let mut st = AdaptState::default();
        for _ in 0..20 {
            st.bump("early_cut_in");
            st.thresholds(&base());
        }
        assert_eq!(st.delta["ep_thr"], ADAPT_MAX);
        assert_eq!(st.thresholds(&base())["ep_thr"], to_fixed_4(base()["ep_thr"] + ADAPT_MAX));
    }

    #[test]
    fn only_base_keys_move_and_rounding_matches_js() {
        let mut st = AdaptState::default();
        st.delta.insert("not_a_param".into(), 0.1);
        st.bump("bc_ok");
        let out = st.thresholds(&base());
        assert!(!out.contains_key("not_a_param"));
        // JS: +(0.5 + -0.02).toFixed(4) === 0.48
        assert_eq!(out["bc_thr"], 0.48);
    }

    #[test]
    fn state_round_trips_the_js_file_shape() {
        let mut st = AdaptState::default();
        st.bump("real_barge");
        st.thresholds(&base());
        let s = serde_json::to_string(&st).unwrap();
        let back: AdaptState = serde_json::from_str(&s).unwrap();
        assert_eq!(st, back);
        // the JS relay's state files parse too (extra keys like `updated` are ignored)
        let js = "{\"counts\":{\"bc_ok\":3},\"delta\":{\"bc_thr\":-0.04},\"updated\":\"2026-10-19T00:00:00Z\"}";
        let from_js: AdaptState = serde_json::from_str(js).unwrap();
        assert_eq!(from_js.delta["bc_thr"], -0.04);
    }
}
