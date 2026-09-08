//! GUI-facing video subscription: decoded adaptive `VideoTrack` -> JPEG
//! frames on disk.
//!
//! The FFI starts a subscription that decodes the remote broadcast (with
//! network-driven rendition adaptation from iroh-live) and continuously
//! writes the latest decoded frame to `video-frame.jpg` (atomic rename) in
//! the media directory. The application core re-loads that file through
//! `Cmd.imageLoad` onto a stable image id on a timer, so the platform image
//! pipeline renders live video without raw pixels crossing the FFI.

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::time::Duration;

use iroh_live::media::{adaptive::AdaptiveConfig, format::DecodeConfig};
use iroh_live::ticket::LiveTicket;
use iroh_live::{Live, Subscription};
use safer_ffi::prelude::*;

use crate::media::media_path;

static VIDEO: Mutex<Option<VideoSession>> = Mutex::new(None);

struct VideoSession {
    stop: Arc<AtomicBool>,
}

/// Starts the video subscription for `ticket`: subscribes, enables network
/// adaptation, and writes decoded frames to `video-frame.jpg` under the
/// media directory (see `media_path`). Returns the absolute frame path for
/// `Cmd.imageLoad`, or an empty string on failure.
#[ffi_export]
pub fn media_video_start(ticket: char_p::Ref<'_>) -> char_p::Box {
    let ticket = ticket.to_str().to_string();

    // Replace any running session.
    media_video_stop();

    let stop = Arc::new(AtomicBool::new(false));
    let stop_loop = stop.clone();
    let frame_path = media_path("video-frame.jpg");
    let tmp_path = media_path("video-frame.jpg.tmp");
    let return_path = frame_path.to_str().unwrap_or("").to_string();

    // Multi-thread runtime on a dedicated thread: the loop runs for the
    // session's lifetime and must not share the caller's executor.
    std::thread::spawn(move || {
        if let Ok(rt) = tokio::runtime::Runtime::new() {
            rt.block_on(video_loop(&ticket, &frame_path, &tmp_path, stop_loop));
        }
    });

    let session = VideoSession { stop };
    match VIDEO.lock() {
        Ok(mut guard) => *guard = Some(session),
        Err(_) => return char_p::new(""),
    }
    char_p::new(return_path.as_str())
}

/// Stops the video subscription and frame writing.
#[ffi_export]
pub fn media_video_stop() {
    if let Ok(mut guard) = VIDEO.lock() {
        if let Some(session) = guard.take() {
            session.stop.store(true, Ordering::Relaxed);
        }
    }
}

async fn video_loop(ticket: &str, frame_path: &std::path::Path, tmp_path: &std::path::Path, stop: Arc<AtomicBool>) {
    let Ok(parsed) = ticket.parse::<LiveTicket>() else {
        eprintln!("video: invalid ticket");
        return;
    };
    let Ok(live) = Live::from_env().await else {
        eprintln!("video: endpoint setup failed");
        return;
    };
    let live = live.spawn();
    // Bounded subscribe: a publisher that never announces must not hang us.
    let subscription: Subscription = match tokio::time::timeout(
        Duration::from_secs(10),
        live.subscribe(parsed.endpoint, &parsed.broadcast_name),
    )
    .await
    {
        Ok(Ok(sub)) => sub,
        Ok(Err(err)) => {
            eprintln!("video subscribe failed: {err:#}");
            return;
        }
        Err(_) => {
            eprintln!("video subscribe timed out");
            return;
        }
    };
    let (_session, broadcast, signals) = subscription.into_parts();
    // video_ready resolves once the catalog has a video track and the
    // decoded track is running.
    let mut track = match tokio::time::timeout(Duration::from_secs(10), broadcast.video_ready()).await {
        Ok(Ok(track)) => track,
        Ok(Err(err)) => {
            eprintln!("video track setup failed: {err:#}");
            return;
        }
        Err(_) => {
            eprintln!("no video track in broadcast");
            return;
        }
    };
    // Network-driven rendition switching: the track re-keys its decoder to
    // the rendition the adaptive controller selects from QUIC signals.
    let _ = track.enable_adaptation(
        broadcast,
        signals,
        AdaptiveConfig::default(),
        DecodeConfig::default(),
    );

    loop {
        if stop.load(Ordering::Relaxed) {
            return;
        }
        match tokio::time::timeout(Duration::from_millis(500), track.next_frame()).await {
            Ok(Some(frame)) => {
                let rgba = frame.rgba_image();
                let mut jpeg = Vec::with_capacity((rgba.width() as usize) * (rgba.height() as usize) / 4);
                let encoder = jpeg_encoder::Encoder::new(&mut jpeg, 80);
                if encoder
                    .encode(
                        rgba.as_raw(),
                        rgba.width().try_into().unwrap_or(0),
                        rgba.height().try_into().unwrap_or(0),
                        jpeg_encoder::ColorType::Rgba,
                    )
                    .is_err()
                {
                    continue;
                }
                // Atomic write: readers never observe a partial JPEG.
                if std::fs::write(tmp_path, &jpeg).is_ok() {
                    let _ = std::fs::rename(tmp_path, frame_path);
                }
            }
            // Track closed (stream ended): keep polling until stopped so a
            // late-restarting broadcast is picked up... it will not; exit.
            Ok(None) => return,
            // No frame in the window: loop re-checks the stop flag.
            Err(_) => {}
        }
    }
}
