//! Current decoded-video FFI bridge.

use std::sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex};
use iroh_live::{ticket::LiveTicket, Live};
use safer_ffi::prelude::*;

use crate::media::media_path;

static VIDEO: Mutex<Option<VideoSession>> = Mutex::new(None);

struct VideoSession { stop: Arc<AtomicBool> }

#[ffi_export]
pub fn media_video_start(ticket: char_p::Ref<'_>) -> char_p::Box {
    media_video_stop();
    let ticket = ticket.to_str().to_owned();
    let frame_path = media_path("video-frame.jpg");
    let temp_path = media_path("video-frame.jpg.tmp");
    let _ = std::fs::remove_file(&frame_path);
    let _ = std::fs::remove_file(&temp_path);
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let return_path = frame_path.to_string_lossy().into_owned();
    std::thread::spawn(move || {
        if let Ok(runtime) = tokio::runtime::Runtime::new() {
            runtime.block_on(video_loop(&ticket, &frame_path, &temp_path, thread_stop));
        }
    });
    *VIDEO.lock().unwrap() = Some(VideoSession { stop });
    return_path.try_into().unwrap()
}

#[ffi_export]
pub fn media_video_stop() {
    if let Some(session) = VIDEO.lock().unwrap().take() {
        session.stop.store(true, Ordering::Relaxed);
    }
}

async fn video_loop(ticket: &str, frame_path: &std::path::Path, temp_path: &std::path::Path, stop: Arc<AtomicBool>) {
    let Ok(ticket) = ticket.parse::<LiveTicket>() else { return };
    let Ok(live) = Live::from_env().await else { return };
    let live = live.spawn();
    let Ok(subscription) = live.subscribe(ticket.endpoint, &ticket.broadcast_name).await else { return };
    let broadcast = subscription.broadcast();
    let Ok(track) = broadcast.video().await else { return };
    track.enable_adaptation(subscription.signals().clone());
    while !stop.load(Ordering::Relaxed) {
        let Some(frame) = track.recv().await else { break };
        let Ok(rgba) = frame.surface.into_rgba() else { continue };
        let mut jpeg = Vec::new();
        let encoder = jpeg_encoder::Encoder::new(&mut jpeg, 80);
        if encoder.encode(rgba.data(), rgba.width() as u16, rgba.height() as u16, jpeg_encoder::ColorType::Rgba).is_ok() {
            if std::fs::write(temp_path, &jpeg).is_ok() { let _ = std::fs::rename(temp_path, frame_path); }
        }
    }
    live.shutdown().await;
}
