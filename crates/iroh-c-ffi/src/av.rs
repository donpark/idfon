//! A/V sync clock: video frames present against the audio playout clock.
//!
//! Audio playout lags the wire (decoder latency budget + PacedPlayback
//! prebuffer + sink buffer ≈ 80–130 ms) while video renders on arrival, so
//! without a gate the picture leads the lips. The audio receive loop anchors
//! the pair (media pts, wall due) at every playback write; the video loop
//! delays early frames to the anchor and drops frames too late to show.

use std::sync::Mutex;
use std::time::{Duration, Instant};

/// An audio playout anchor: media at `audio_pts_us` reaches the speaker at
/// `audio_due`.
#[derive(Clone, Copy)]
struct Anchor {
    audio_pts_us: u64,
    audio_due: Instant,
}

static ANCHOR: Mutex<Option<Anchor>> = Mutex::new(None);

/// How far ahead of its due time a video frame waits before presenting
/// anyway (audio stalled or anchor lost).
const WAIT_CAP: Duration = Duration::from_millis(250);
/// How late a video frame may present; beyond this it is stale and dropped.
const LATE_DROP: Duration = Duration::from_millis(250);

fn anchor_slot() -> std::sync::MutexGuard<'static, Option<Anchor>> {
    ANCHOR.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// Forget the anchor (call start/stop). Without one, video presents on
/// arrival — the pre-sync behavior.
pub fn reset() {
    *anchor_slot() = None;
}

/// Record that audio stamped `pts_us` reaches the speaker at
/// `now + playout_delay`.
pub fn anchor_audio(pts_us: u64, playout_delay: Duration) {
    *anchor_slot() = Some(Anchor {
        audio_pts_us: pts_us,
        audio_due: Instant::now() + playout_delay,
    });
}

/// What to do with a video frame stamped `pts_us`.
pub enum Decision {
    /// On time (or no anchor): present now.
    Present,
    /// Early: present at the given instant.
    Wait(Instant),
    /// Too late to show: drop it.
    Drop,
}

/// Decide when a video frame stamped `pts_us` should present.
pub fn decide(pts_us: u64) -> Decision {
    let now = Instant::now();
    let Some(anchor) = *anchor_slot() else {
        return Decision::Present;
    };
    let due = if pts_us >= anchor.audio_pts_us {
        anchor.audio_due + Duration::from_micros(pts_us - anchor.audio_pts_us)
    } else {
        match anchor
            .audio_due
            .checked_sub(Duration::from_micros(anchor.audio_pts_us - pts_us))
        {
            Some(due) => due,
            // Frame predates anything the anchor covers: already stale.
            None => return Decision::Drop,
        }
    };
    if now > due + LATE_DROP {
        Decision::Drop
    } else if due > now + WAIT_CAP {
        // The anchor describes audio that is not playing (stall): show what
        // we have rather than freezing the picture on a dead clock.
        Decision::Present
    } else if due > now {
        Decision::Wait(due)
    } else {
        Decision::Present
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The anchor is process-global; serialize tests against each other.
    static LOCK: Mutex<()> = Mutex::new(());

    fn locked() -> std::sync::MutexGuard<'static, ()> {
        LOCK.lock().unwrap_or_else(|poison| poison.into_inner())
    }

    #[test]
    fn no_anchor_presents_immediately() {
        let _guard = locked();
        reset();
        assert!(matches!(decide(12_345), Decision::Present));
    }

    #[test]
    fn early_video_waits_for_the_audio_clock() {
        let _guard = locked();
        reset();
        anchor_audio(1_000, Duration::from_millis(100));
        // Video 10 ms of media after the anchored audio → due ~110 ms out.
        match decide(11_000) {
            Decision::Wait(due) => {
                let out = due.duration_since(Instant::now());
                assert!(out <= Duration::from_millis(110), "{out:?}");
            }
            other => {
                let _ = other;
                panic!("expected Wait");
            }
        }
    }

    #[test]
    fn stale_frame_is_dropped() {
        let _guard = locked();
        reset();
        anchor_audio(1_000, Duration::ZERO);
        std::thread::sleep(Duration::from_millis(300));
        assert!(matches!(decide(1_000), Decision::Drop));
    }

    #[test]
    fn dead_anchor_does_not_freeze_video() {
        let _guard = locked();
        reset();
        // Audio claimed a 10 s future playout: beyond WAIT_CAP, present now.
        anchor_audio(1_000, Duration::from_secs(10));
        assert!(matches!(decide(1_000), Decision::Present));
    }

    #[test]
    fn video_before_the_anchor_still_presents() {
        let _guard = locked();
        reset();
        anchor_audio(50_000, Duration::from_millis(100));
        // 49 ms of media before the anchored audio: due 51 ms out, a wait.
        assert!(matches!(decide(1_000), Decision::Wait(_)));
    }
}
