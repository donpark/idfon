//! Current decoded-video FFI bridge.

use std::{sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex, OnceLock}, time::Duration};
use iroh_live::{ticket::LiveTicket, Live};
use safer_ffi::prelude::*;

use crate::media::media_path;

static VIDEO: Mutex<Option<VideoSession>> = Mutex::new(None);
static VIDEO_ERROR: OnceLock<Mutex<String>> = OnceLock::new();

/// How long the frame artifact survives without a new decoded frame. The
/// publisher keeps its video track open while the camera is off (the encoder
/// idles), so silence is "peer camera off": remove the artifact so the shell
/// clears the stale picture instead of presenting it as live.
const FRAME_IDLE: Duration = Duration::from_secs(2);
/// How often the loop re-checks the stop flag while waiting on the peer.
const STOP_POLL: Duration = Duration::from_millis(100);

fn video_error(message: impl Into<String>) {
    if let Ok(mut error) = VIDEO_ERROR.get_or_init(|| Mutex::new(String::new())).lock() {
        *error = message.into();
    }
}

struct VideoSession { stop: Arc<AtomicBool> }

#[ffi_export]
pub fn media_video_start(ticket: char_p::Ref<'_>) -> char_p::Box {
    media_video_stop();
    video_error(""); // a stale error from the previous session must not fail this one
    let ticket = ticket.to_str().to_owned();
    let frame_path = media_path("video-frame.jpg");
    let temp_path = media_path("video-frame.jpg.tmp");
    let _ = std::fs::remove_file(&frame_path);
    let _ = std::fs::remove_file(&temp_path);
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let return_path = frame_path.to_string_lossy().into_owned();
    std::thread::spawn(move || {
        let Ok(runtime) = tokio::runtime::Runtime::new() else {
            video_error("video runtime creation failed");
            return;
        };
        runtime.block_on(video_loop(&ticket, &frame_path, &temp_path, thread_stop));
    });
    *VIDEO.lock().unwrap() = Some(VideoSession { stop });
    return_path.try_into().unwrap()
}

#[ffi_export]
pub fn media_video_last_error() -> char_p::Box {
    VIDEO_ERROR.get_or_init(|| Mutex::new(String::new())).lock().map(|error| error.clone()).unwrap_or_default().try_into().unwrap()
}

#[ffi_export]
pub fn media_video_stop() {
    if let Some(session) = VIDEO.lock().unwrap().take() {
        session.stop.store(true, Ordering::Relaxed);
    }
}

async fn video_loop(ticket: &str, frame_path: &std::path::Path, temp_path: &std::path::Path, stop: Arc<AtomicBool>) {
    let ticket = match ticket.parse::<LiveTicket>() {
        Ok(ticket) => ticket,
        Err(error) => { video_error(format!("ticket parse failed: {error}")); return; }
    };
    let live = match Live::from_env().await {
        Ok(live) => live.spawn(),
        Err(error) => { video_error(format!("live init failed: {error}")); return; }
    };
    let subscription = match live.subscribe(ticket.endpoint, &ticket.broadcast_name).await {
        Ok(subscription) => subscription,
        Err(error) => { video_error(format!("video subscribe failed: {error}")); return; }
    };
    let broadcast = subscription.broadcast();
    // The publisher registers its video rendition only once the first camera
    // frame reaches the encoder (moq-media `VideoSource::Frames` derives the
    // catalog geometry from it), and a mic-first call may not switch the camera
    // on for a while. The first catalog is therefore audio-only or empty; wait
    // for the rendition instead of failing on that snapshot.
    while !broadcast.has_video() {
        if stop.load(Ordering::Relaxed) { live.shutdown().await; return; }
        tokio::time::sleep(STOP_POLL).await;
    }
    let track = match broadcast.video().await {
        Ok(track) => track,
        Err(error) => { video_error(format!("video track failed: {error}")); live.shutdown().await; return; }
    };
    track.enable_adaptation(subscription.signals().clone());
    while !stop.load(Ordering::Relaxed) {
        // `VideoTrack::recv` is a cancel-safe latest-frame slot, so bounding it
        // keeps hangup prompt and lets an idle track clear the artifact.
        let frame = match tokio::time::timeout(FRAME_IDLE, track.recv()).await {
            Ok(Some(frame)) => frame,
            Ok(None) => break,
            Err(_) => { let _ = std::fs::remove_file(frame_path); continue; }
        };
        let Ok(rgba) = frame.surface.into_rgba() else { continue };
        let mut jpeg = Vec::new();
        let encoder = jpeg_encoder::Encoder::new(&mut jpeg, 80);
        if encoder.encode(rgba.data(), rgba.width() as u16, rgba.height() as u16, jpeg_encoder::ColorType::Rgba).is_ok() {
            if std::fs::write(temp_path, &jpeg).is_ok() { let _ = std::fs::rename(temp_path, frame_path); }
        } else {
            video_error("video JPEG encode failed");
        }
    }
    // Track ended or the session stopped: nothing on disk is live any more.
    let _ = std::fs::remove_file(frame_path);
    live.shutdown().await;
}
