//! Audio ABR: retune the live Opus encoder from the connection's send
//! estimate (docs/media-adaptation.md §C5).
//!
//! The mic audio publishes on the session the peer dialed in on, and that
//! session's congestion controller knows what the uplink can carry:
//! [`Session::send_bandwidth`](moq_net::Session::send_bandwidth) — the same
//! estimate moq-net mirrors to subscribers as `delivery_bps`. The house rate
//! policy ([`moq_video::encode::rate`], "every sender backs off the same way")
//! turns estimates into targets, and a [`BitrateControl`] hands them to the
//! encoder the publish task owns (see `Options::bitrate_control` in moq-audio).
//!
//! The encoder starts at its configured rate and the estimate only takes it
//! down or back up within the voice band: 8–64 kbps per channel, never above
//! configured. A caller that configured more (music via
//! `media_audio_set_bitrate`) made that choice explicitly; ABR stands down
//! rather than fight it.

use std::sync::Mutex;
use std::time::Instant;

use iroh_live::Live;
use moq_audio::encode::BitrateControl;
use moq_mux::rate::{Control, Policy};
use moq_net::bandwidth::Rate;

/// The voice band `Producer::set_bitrate` is clamped to, in bits per second
/// per channel. The floor is where speech stops being worth sending; the
/// ceiling is where it stops getting better (and matches the floor of
/// `media_audio_set_bitrate`, which is per-channel too).
const BAND_MIN: u64 = 8_000;
const BAND_MAX: u64 = 64_000;

/// The control of the call being published, for track rebuilds that must keep
/// driving the same encoder (the FEC flip restarts the track).
static CONTROL: Mutex<Option<BitrateControl>> = Mutex::new(None);

/// Start driving `live`'s publish encoder from the send estimates of the
/// sessions peers open on it. Returns the shared control to attach to the
/// audio `Options`, or `None` when the configured rate is outside the voice
/// band (ABR stands down) or the codec cannot retune.
pub(crate) fn start(live: &Live, configured_bps: u64, channels: u32) -> Option<BitrateControl> {
    let Some(policy) = voice_policy(configured_bps, channels) else {
        // Outside the voice band the configured rate is the caller's explicit
        // choice (music): no control, no driver, nothing to hand a rebuild.
        *CONTROL.lock().unwrap_or_else(|poison| poison.into_inner()) = None;
        return None;
    };
    let control = BitrateControl::new();
    *CONTROL.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(control.clone());

    let moq = live.transport().clone();
    let driving = control.clone();
    crate::util::TOKIO_EXECUTOR.spawn(async move {
        let mut sessions = moq.incoming_sessions();
        while let Some(session) = sessions.next().await {
            let Some(send) = session.session().send_bandwidth() else {
                continue;
            };
            // Drive from this session until it goes: a re-subscribe replaces
            // it with the next one the peer opens.
            let mut send = send;
            let mut rate = Control::new(policy.clone());
            if let Some(target) = rate.update(send.peek(), Instant::now()) {
                driving.set(target.as_bps());
            }
            loop {
                tokio::select! {
                    _ = session.closed() => break,
                    changed = send.changed() => {
                        let Ok(estimate) = changed else { break };
                        if let Some(target) = rate.update(estimate, Instant::now()) {
                            driving.set(target.as_bps());
                        }
                    }
                }
            }
        }
    });
    Some(control)
}

/// The control of the running call, for a rebuild of its audio track.
pub(crate) fn control() -> Option<BitrateControl> {
    CONTROL.lock().unwrap_or_else(|poison| poison.into_inner()).clone()
}

/// Call end: forget the control so nothing can attach a dead call's request
/// to the next one. The driver task winds down on its own as the sessions
/// close with the transport.
pub(crate) fn stop() {
    *CONTROL.lock().unwrap_or_else(|poison| poison.into_inner()) = None;
}

/// The rate policy for a call configured at `configured_bps` total over
/// `channels` channels: within the voice band per channel, capped at the
/// configured rate (an optimistic estimate is not a reason to send more than
/// was asked for). `None` = stand down, leave the encoder alone.
fn voice_policy(configured_bps: u64, channels: u32) -> Option<Policy> {
    let channels = u64::from(channels.max(1));
    let per_channel = configured_bps / channels;
    if !(BAND_MIN..=BAND_MAX).contains(&per_channel) {
        return None;
    }
    let mut policy = Policy::new(Rate::from_bps(configured_bps));
    policy.min = Rate::from_bps(BAND_MIN * channels);
    Some(policy)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn voice_policy_clamps_the_voice_band_per_channel() {
        // Mono voice at the 36 kbps default: floor 8k, ceiling = configured.
        let policy = voice_policy(36_000, 1).unwrap();
        assert_eq!(policy.max.as_bps(), 36_000);
        assert_eq!(policy.min.as_bps(), 8_000);

        // Stereo voice at 48 kbps/channel: both ends scale with channels.
        let policy = voice_policy(96_000, 2).unwrap();
        assert_eq!(policy.max.as_bps(), 96_000);
        assert_eq!(policy.min.as_bps(), 16_000);
    }

    #[test]
    fn voice_policy_stands_down_outside_the_band() {
        assert!(voice_policy(1_020_000, 2).is_none(), "music rates are the caller's choice");
        assert!(voice_policy(4_000, 1).is_none(), "below the band, keep the configured rate");
    }

    #[test]
    fn estimates_never_take_the_target_above_configured() {
        let mut rate = Control::new(voice_policy(36_000, 1).unwrap());
        assert_eq!(
            rate.update(Some(Rate::from_bps(10_000_000)), Instant::now()),
            None,
            "an optimistic estimate changes nothing"
        );
        assert!(rate.target().as_bps() <= 36_000);
        // A starved uplink takes it down at once, into the band.
        let target = rate.update(Some(Rate::from_bps(12_000)), Instant::now()).unwrap();
        assert!(
            (8_000..=36_000).contains(&target.as_bps()),
            "target {} left the voice band",
            target.as_bps()
        );
    }
}
