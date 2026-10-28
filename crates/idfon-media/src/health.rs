//! Connection health-check tracing (docs/media-adaptation.md §B2.2).
//!
//! The pure tracing feature: fold what each endpoint measured about its own
//! downlink over a check window into one report with a verdict and the
//! actions that would improve the call. Presentation is per app; this module
//! owns no UI. The report schema and [`Progress`] events are the contract
//! between this module and any shell, CLI, or agent that runs a check.

use serde::{Deserialize, Serialize};

/// One network sample: the transport's view of its own downlink at an instant.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Sample {
    /// Round-trip time in milliseconds.
    pub rtt_ms: u64,
    /// The path's idle round trip in milliseconds, for reading `rtt_ms` as queueing.
    pub min_rtt_ms: u64,
    /// Recent packet loss, percent.
    pub loss_pct: f64,
    /// Downlink goodput in kbps, or `None` while too little arrives to measure.
    pub goodput_kbps: Option<u64>,
}

/// What one endpoint measured over the check window.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Leg {
    /// Smallest round trip seen: the path's idle delay.
    pub rtt_ms_min: u64,
    /// Largest round trip seen: queueing shows here.
    pub rtt_ms_max: u64,
    /// Mean packet loss, percent.
    pub loss_pct_mean: f64,
    /// Mean downlink goodput in kbps, or `None` when never measurable.
    pub goodput_kbps_mean: Option<u64>,
    /// Audio the local playout could not deliver in time, in samples.
    pub audio_underrun_samples: u64,
}

impl Leg {
    /// Fold the window's samples. `audio_underrun_samples` counts the local
    /// playout samples lost during the same window.
    pub fn fold(samples: &[Sample], audio_underrun_samples: u64) -> Self {
        let mut leg = Self {
            audio_underrun_samples,
            ..Self::default()
        };
        if samples.is_empty() {
            return leg;
        }
        leg.rtt_ms_min = samples.iter().map(|s| s.rtt_ms).min().unwrap_or(0);
        leg.rtt_ms_max = samples.iter().map(|s| s.rtt_ms).max().unwrap_or(0);
        leg.loss_pct_mean = samples.iter().map(|s| s.loss_pct).sum::<f64>() / samples.len() as f64;
        let goodputs: Vec<u64> = samples.iter().filter_map(|s| s.goodput_kbps).collect();
        if !goodputs.is_empty() {
            leg.goodput_kbps_mean = Some(goodputs.iter().sum::<u64>() / goodputs.len() as u64);
        }
        leg
    }
}

/// A call's media state, so a tip never suggests an action already taken.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Context {
    /// Whether the call carries video.
    pub video_on: bool,
    /// Whether the call is stereo.
    pub stereo: bool,
}

/// An action that improves the call on a weak link. The same actions the
/// automatic policy degrades along: a button and the policy call one seam.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    TurnOffVideo,
    TurnOffStereo,
    LowerVideo,
    RelayOnly,
}

/// One suggestion, with the measurement that motivates it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tip {
    pub action: Action,
    /// Human-readable motive. A shell renders it; an agent narrates it.
    pub reason: String,
}

/// How the link fared over the check window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Good,
    Fair,
    Poor,
}

/// The check result: what was measured and what would improve it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub local: Leg,
    /// The far leg once the two-end exchange lands; `None` is a one-sided check.
    pub remote: Option<Leg>,
    pub verdict: Verdict,
    pub tips: Vec<Tip>,
}

/// Progress a runner emits while a check runs. Shells get it as JSON.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Progress {
    /// Sampling is running: `elapsed_ms` of `total_ms` done.
    Sampling { elapsed_ms: u64, total_ms: u64 },
    /// The check is over.
    Done { report: Report },
}

// Rule thresholds. Percent loss and kbps are the knobs a future calibration
// pass (C1 records) may move; keep them together and named.
const LOSS_FAIR_PCT: f64 = 1.0;
const LOSS_POOR_PCT: f64 = 5.0;
const LOSS_VIDEO_OFF_PCT: f64 = 3.0;
const GOODPUT_LOW_KBPS: u64 = 600;
const GOODPUT_CRITICAL_KBPS: u64 = 300;
const QUEUE_RATIO: u64 = 3;
const QUEUE_MIN_MS: u64 = 150;
/// Underruns above this many samples (about 100 ms at 48 kHz) mean the
/// listener heard a dropout.
const UNDERRUN_AUDIBLE: u64 = 4_800;

impl Report {
    /// A one-sided check: local measurements only.
    pub fn one_sided(local: Leg, context: Context) -> Self {
        Self::build(local, None, context)
    }

    /// A merged check: both legs measured. The verdict takes the worse leg,
    /// and either leg may motivate a tip.
    pub fn merged(local: Leg, remote: Leg, context: Context) -> Self {
        Self::build(local, Some(remote), context)
    }

    fn build(local: Leg, remote: Option<Leg>, context: Context) -> Self {
        let mut verdict = Verdict::Good;
        let mut tips = Vec::new();
        let mut legs = vec![("local", &local)];
        if let Some(remote) = &remote {
            legs.push(("remote", remote));
        }
        for (who, leg) in legs {
            let worse = leg_verdict(leg);
            if rank(worse) > rank(verdict) {
                verdict = worse;
            }

            if context.video_on
                && (leg.loss_pct_mean >= LOSS_VIDEO_OFF_PCT
                    || leg.audio_underrun_samples > UNDERRUN_AUDIBLE
                    || leg.goodput_kbps_mean.is_some_and(|k| k < GOODPUT_CRITICAL_KBPS))
            {
                tips.push(Tip {
                    action: Action::TurnOffVideo,
                    reason: format!("{who} leg: video carries the most bytes; the audio would stop breaking up"),
                });
            } else if context.video_on
                && leg.goodput_kbps_mean.is_some_and(|k| k < GOODPUT_LOW_KBPS)
            {
                tips.push(Tip {
                    action: Action::LowerVideo,
                    reason: format!("{who} leg: goodput is under {GOODPUT_LOW_KBPS} kbps; a lower video quality would hold"),
                });
            }
            if context.stereo && leg.loss_pct_mean >= LOSS_FAIR_PCT {
                tips.push(Tip {
                    action: Action::TurnOffStereo,
                    reason: format!("{who} leg: mono halves the audio bitrate and loss is {:.1}%", leg.loss_pct_mean),
                });
            }
            if queues(leg) {
                tips.push(Tip {
                    action: Action::RelayOnly,
                    reason: format!(
                        "{who} leg: round trip queues from {} ms to {} ms; a different path (relay) may be cleaner",
                        leg.rtt_ms_min, leg.rtt_ms_max
                    ),
                });
            }
        }
        Self { local, remote, verdict, tips }
    }
}

fn leg_verdict(leg: &Leg) -> Verdict {
    if leg.loss_pct_mean >= LOSS_POOR_PCT || leg.audio_underrun_samples > UNDERRUN_AUDIBLE {
        Verdict::Poor
    } else if leg.loss_pct_mean >= LOSS_FAIR_PCT || leg.audio_underrun_samples > 0 || queues(leg) {
        Verdict::Fair
    } else {
        Verdict::Good
    }
}

fn queues(leg: &Leg) -> bool {
    leg.rtt_ms_max >= QUEUE_MIN_MS && leg.rtt_ms_max >= leg.rtt_ms_min.max(1) * QUEUE_RATIO
}

fn rank(verdict: Verdict) -> u8 {
    match verdict {
        Verdict::Good => 0,
        Verdict::Fair => 1,
        Verdict::Poor => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(rtt_ms: u64, loss_pct: f64) -> Sample {
        Sample {
            rtt_ms,
            min_rtt_ms: 20,
            loss_pct,
            goodput_kbps: Some(2_000),
        }
    }

    #[test]
    fn a_healthy_link_verdicts_good_with_no_tips() {
        let leg = Leg::fold(&[sample(25, 0.0), sample(30, 0.1)], 0);
        let report = Report::one_sided(leg, Context { video_on: true, stereo: true });
        assert_eq!(report.verdict, Verdict::Good);
        assert!(report.tips.is_empty());
    }

    #[test]
    fn loss_on_a_video_call_suggests_dropping_video() {
        let leg = Leg::fold(&[sample(60, 4.0)], 0);
        let report = Report::one_sided(leg, Context { video_on: true, stereo: false });
        assert_eq!(report.verdict, Verdict::Fair);
        assert!(report.tips.iter().any(|t| t.action == Action::TurnOffVideo));
    }

    #[test]
    fn stereo_on_a_lossy_link_suggests_mono() {
        let leg = Leg::fold(&[sample(60, 1.5)], 0);
        let report = Report::one_sided(leg, Context { video_on: false, stereo: true });
        assert!(report.tips.iter().any(|t| t.action == Action::TurnOffStereo));
    }

    #[test]
    fn queueing_suggests_a_different_path() {
        let leg = Leg::fold(&[sample(20, 0.0), sample(200, 0.0)], 0);
        let report = Report::one_sided(leg, Context::default());
        assert!(report.tips.iter().any(|t| t.action == Action::RelayOnly));
    }

    #[test]
    fn audible_underruns_verdict_poor() {
        let leg = Leg::fold(&[sample(25, 0.0)], 5_000);
        let report = Report::one_sided(leg, Context::default());
        assert_eq!(report.verdict, Verdict::Poor);
    }

    #[test]
    fn a_merged_check_takes_the_worse_leg_and_tips_from_both() {
        let local = Leg::fold(&[sample(25, 0.0)], 0);
        let remote = Leg::fold(&[sample(60, 4.0)], 0);
        let report = Report::merged(local, remote, Context { video_on: true, stereo: false });
        assert_eq!(report.verdict, Verdict::Fair);
        assert!(report.tips.iter().any(|t| t.action == Action::TurnOffVideo));
        assert!(report.remote.is_some());
    }

    #[test]
    fn progress_serializes_as_tagged_json() {
        let json = serde_json::to_string(&Progress::Sampling {
            elapsed_ms: 250,
            total_ms: 1_000,
        })
        .unwrap();
        assert_eq!(json, r#"{"kind":"sampling","elapsed_ms":250,"total_ms":1000}"#);
    }
}
