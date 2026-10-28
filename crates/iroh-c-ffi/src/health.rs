//! Health-check runner (docs/media-adaptation.md §B2.2).
//!
//! The shell-agnostic half of the seam: sample the live session's network
//! signals over a check window and emit `idfon_media::health::Progress` JSON
//! through a callback. Shells own progress presentation and action buttons;
//! this module only traces.

use std::ffi::c_void;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use moq_media::net::NetworkSignals;
use safer_ffi::prelude::*;
use tokio::sync::watch;

use idfon_media::health::{Context, Leg, Progress, Report, Sample};

static SIGNALS: Mutex<Option<watch::Receiver<NetworkSignals>>> = Mutex::new(None);
static CHANNELS: AtomicU64 = AtomicU64::new(1);

/// Attach the live session's signals so checks can sample them. Call it when
/// a subscription is established; the last one wins per call.
pub(crate) fn attach(signals: watch::Receiver<NetworkSignals>) {
    *SIGNALS.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(signals);
}

/// The live session's channel count, for the mono/stereo tips.
pub(crate) fn set_channels(channels: u64) {
    CHANNELS.store(channels.max(1), Ordering::Relaxed);
}

fn take_sample(signals: &watch::Receiver<NetworkSignals>) -> Sample {
    let signals = signals.borrow();
    Sample {
        rtt_ms: signals.rtt.as_millis() as u64,
        min_rtt_ms: signals.min_rtt.as_millis() as u64,
        loss_pct: signals.loss_rate * 100.0,
        goodput_kbps: signals.goodput_bps.map(|bps| bps / 1_000),
    }
}

/// Run a health check over the live session and report through `cb`.
///
/// `cb` receives JSON (`idfon_media::health::Progress`): `sampling` events
/// while the window runs, then one `done` event carrying the report. The last
/// argument tells them apart (1 = done). Returns 0 when the check started,
/// 1 when no live session is attached.
#[ffi_export]
pub fn media_health_check(
    ctx: *const c_void,
    cb: unsafe extern "C" fn(*const c_void, *const u8, usize, u8),
    duration_ms: u64,
) -> u8 {
    let Some(signals) = SIGNALS
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .clone()
    else {
        return 1;
    };
    let ctx = ctx as usize;
    let duration = Duration::from_millis(duration_ms.clamp(1, 60_000));
    std::thread::spawn(move || {
        let emit = |progress: &Progress| {
            if let Ok(json) = serde_json::to_vec(progress) {
                let done = u8::from(matches!(progress, Progress::Done { .. }));
                // SAFETY: the shell owns the context and must keep it valid
                // for the duration of the check (documented contract).
                unsafe { cb(ctx as *const c_void, json.as_ptr(), json.len(), done) };
            }
        };
        let start = Instant::now();
        let underruns_at_start = crate::media::underruns();
        let mut samples = Vec::new();
        while start.elapsed() < duration {
            std::thread::sleep(Duration::from_millis(250).min(duration));
            samples.push(take_sample(&signals));
            emit(&Progress::Sampling {
                elapsed_ms: start.elapsed().as_millis() as u64,
                total_ms: duration_ms,
            });
        }
        let underruns = crate::media::underruns().saturating_sub(underruns_at_start);
        let local = Leg::fold(&samples, underruns);
        let context = Context {
            video_on: crate::media::video_enabled(),
            stereo: CHANNELS.load(Ordering::Relaxed) > 1,
        };
        emit(&Progress::Done {
            report: Report::one_sided(local, context),
        });
    });
    0
}
