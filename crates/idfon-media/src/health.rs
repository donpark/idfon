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

// --- Per-call quality record (docs/media-adaptation.md §C1) --------------

/// One timeline point: the transport's own numbers at an instant.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct NetPoint {
    /// Milliseconds since sampling started.
    pub t_ms: u64,
    /// Round-trip time in milliseconds.
    pub rtt_ms: u64,
    /// The path's idle round trip in milliseconds.
    pub min_rtt_ms: u64,
    /// Recent packet loss, percent.
    pub loss_pct: f64,
    /// Downlink goodput in kbps, or `None` while too little arrives to measure.
    pub goodput_kbps: Option<u64>,
    /// Whether the selected path is a relay path (false = direct).
    pub relay: bool,
}

/// A selected-path change during the call; the first entry is the path
/// sampling started on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PathSwitch {
    /// Milliseconds since sampling started.
    pub t_ms: u64,
    /// The newly selected path's id (debug form).
    pub path: String,
    /// Whether the new path is a relay path.
    pub relay: bool,
}

/// ListenStats-style measurements of the call's downlink decode path.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct AudioStats {
    /// Decoded frames.
    pub frames: u64,
    /// Decoded audio duration in milliseconds.
    pub duration_ms: u64,
    /// Subscribe start to the first decoded frame (ms).
    pub startup_ms: u64,
    /// Standard deviation of frame-arrival intervals (ms).
    pub arrival_jitter_ms: f64,
    /// Largest interval between consecutive frames (ms).
    pub max_gap_ms: u64,
    /// Arrival gaps longer than 100 ms (would drain any small play buffer).
    pub stalls_over_100ms: u64,
    /// Frames missing from pts discontinuities.
    pub missing_frames: u64,
    /// Capture-side starvation samples: mic samples the encoder had to pad.
    pub underrun_samples: u64,
}

/// Running fold of the decode path's frame arrivals. Fed per decoded frame
/// (across re-subscribes too), folded at hangup into [`AudioStats`]. Gaps and
/// pts discontinuities are computed here from consecutive frames, so a
/// re-subscribe attempt boundary shows up as the stall it was.
#[derive(Debug, Clone, Copy)]
pub struct AudioArrival {
    frames: u64,
    startup_us: u64,
    media_us: u64,
    gap_sum_us: u128,
    gap_sq_sum: f64,
    max_gap_us: u64,
    stalls_over_100ms: u64,
    missing_frames: u64,
    last_arrival_us: u64,
    last_pts_us: u64,
    last_pts_gap_us: u64,
}

impl AudioArrival {
    /// Starts an empty fold.
    pub const fn new() -> Self {
        Self {
            frames: 0,
            startup_us: 0,
            media_us: 0,
            gap_sum_us: 0,
            gap_sq_sum: 0.0,
            max_gap_us: 0,
            stalls_over_100ms: 0,
            missing_frames: 0,
            last_arrival_us: 0,
            last_pts_us: 0,
            last_pts_gap_us: 0,
        }
    }

    /// One decoded frame: `arrival_us` since subscribe start, `pts_us` on the
    /// media clock, `pts_gap_us` of media the frame carries.
    pub fn record(&mut self, arrival_us: u64, pts_us: u64, pts_gap_us: u64) {
        if self.frames == 0 {
            self.startup_us = arrival_us;
        } else {
            let gap = arrival_us.saturating_sub(self.last_arrival_us);
            self.gap_sum_us += gap as u128;
            self.gap_sq_sum += (gap as f64) * (gap as f64);
            self.max_gap_us = self.max_gap_us.max(gap);
            if gap > 100_000 {
                self.stalls_over_100ms += 1;
            }
            // A pts jump beyond the frame's own duration is lost media.
            let expected = self.last_pts_us + self.last_pts_gap_us;
            self.missing_frames += pts_us.saturating_sub(expected) / pts_gap_us.max(1);
        }
        self.frames += 1;
        self.media_us += pts_gap_us;
        self.last_arrival_us = arrival_us;
        self.last_pts_us = pts_us;
        self.last_pts_gap_us = pts_gap_us;
    }

    /// The fold, with `underrun_samples` (the capture-side counter) attached.
    pub fn stats(&self, underrun_samples: u64) -> AudioStats {
        let n = self.frames.saturating_sub(1) as f64;
        let mean = if n > 0.0 {
            self.gap_sum_us as f64 / n
        } else {
            0.0
        };
        let var = if n > 0.0 {
            self.gap_sq_sum / n - mean * mean
        } else {
            0.0
        };
        AudioStats {
            frames: self.frames,
            duration_ms: self.media_us / 1_000,
            startup_ms: self.startup_us / 1_000,
            arrival_jitter_ms: var.max(0.0).sqrt() / 1_000.0,
            max_gap_ms: self.max_gap_us / 1_000,
            stalls_over_100ms: self.stalls_over_100ms,
            missing_frames: self.missing_frames,
            underrun_samples,
        }
    }
}

impl Default for AudioArrival {
    fn default() -> Self {
        Self::new()
    }
}

/// The per-call quality record (media-adaptation §C1): what the call measured
/// about itself, folded at hangup and shipped to telemetry and `Diag`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CallRecord {
    /// Wall-clock (ms since epoch) when sampling started.
    pub started_ms: u64,
    /// Sampling span in milliseconds.
    pub duration_ms: u64,
    /// The call's media form (video, stereo).
    pub context: Context,
    /// Downlink decode-path audio stats.
    pub audio: AudioStats,
    /// The health fold: verdict and the actions that would improve the call.
    pub report: Report,
    /// Network signals over the call, decimated to [`TIMELINE_CAP`] points.
    pub timeline: Vec<NetPoint>,
    /// Selected-path changes, the first entry being the path at sampling start.
    pub path_switches: Vec<PathSwitch>,
}

/// Cap for [`CallRecord::timeline`]: on overflow the fold keeps every
/// `stride`-th point (and the last), so the whole call stays covered.
/// shortcut: full resolution only covers ~5 min at the 500 ms sample step; a
/// short transition can fall between points on longer calls — windowed
/// min/max buckets if that bites (media-adaptation C2).
pub const TIMELINE_CAP: usize = 600;

/// Uniformly decimate `points` to at most `cap`, keeping the last point.
pub fn decimate(points: &[NetPoint], cap: usize) -> Vec<NetPoint> {
    if points.len() <= cap || cap == 0 {
        return points.to_vec();
    }
    let stride = (points.len() + cap - 1) / cap;
    let mut out: Vec<NetPoint> = points.iter().step_by(stride).copied().collect();
    if out.last() != points.last() {
        out.push(points[points.len() - 1]);
    }
    out
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
                    reason: format!("{who} leg: mono halves the audio bitrate and turns on loss recovery (FEC); loss is {:.1}%", leg.loss_pct_mean),
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

    fn point(t_ms: u64) -> NetPoint {
        NetPoint {
            t_ms,
            rtt_ms: 25,
            min_rtt_ms: 20,
            loss_pct: 0.0,
            goodput_kbps: Some(2_000),
            relay: false,
        }
    }

    #[test]
    fn decimate_keeps_the_last_point_and_a_bounded_count() {
        let points: Vec<NetPoint> = (0..10).map(point).collect();
        let out = decimate(&points, 4);
        assert!(out.len() <= 4);
        assert_eq!(out.first().unwrap().t_ms, 0);
        assert_eq!(out.last().unwrap().t_ms, 9);
    }

    #[test]
    fn decimate_passes_short_timelines_through() {
        let points: Vec<NetPoint> = (0..3).map(point).collect();
        assert_eq!(decimate(&points, 4), points);
    }

    #[test]
    fn audio_arrival_folds_gaps_jitter_and_missing_frames() {
        let mut arrival = AudioArrival::new();
        arrival.record(100_000, 0, 20_000); // first frame: startup, no gap
        arrival.record(120_000, 20_000, 20_000); // on time
        arrival.record(180_000, 80_000, 20_000); // 60 ms stall + 2 lost frames
        let stats = arrival.stats(5_000);
        assert_eq!(stats.frames, 3);
        assert_eq!(stats.duration_ms, 60);
        assert_eq!(stats.startup_ms, 100);
        assert_eq!(stats.max_gap_ms, 60);
        assert_eq!(stats.stalls_over_100ms, 0); // 60 ms gap is not a stall
        assert_eq!(stats.missing_frames, 2);
        assert_eq!(stats.underrun_samples, 5_000);
        // gaps 20 ms and 60 ms → mean 40, stddev 20
        assert!((stats.arrival_jitter_ms - 20.0).abs() < 1e-6);
    }

    #[test]
    fn audio_arrival_counts_100ms_gaps_as_stalls() {
        let mut arrival = AudioArrival::new();
        arrival.record(0, 0, 20_000);
        arrival.record(250_000, 20_000, 20_000);
        let stats = arrival.stats(0);
        assert_eq!(stats.stalls_over_100ms, 1);
    }

    #[test]
    fn an_empty_audio_fold_is_all_zeroes() {
        let stats = AudioArrival::new().stats(7);
        assert_eq!(stats.frames, 0);
        assert_eq!(stats.arrival_jitter_ms, 0.0);
        assert_eq!(stats.underrun_samples, 7);
    }
}
