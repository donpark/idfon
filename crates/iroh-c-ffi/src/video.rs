//! Current decoded-video FFI bridge.

use iroh_live::{ticket::LiveTicket, Live};
use safer_ffi::prelude::*;
use std::{
    ffi::c_void,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};

use idfon_media::seam::VideoRender;
use moq_video::Frame as VideoFrame;

use crate::media::media_path;

static VIDEO: Mutex<Option<VideoSession>> = Mutex::new(None);
static VIDEO_ERROR: OnceLock<Mutex<String>> = OnceLock::new();

/// Stored as `usize` so the function pointer survives a static `Mutex`.
type RenderFn = unsafe extern "C" fn(*const c_void, *const u8, usize, u32, u32, u64);

/// Optional shell-owned in-memory renderer. When absent, decoded frames fall
/// back to the on-disk `video-frame.jpg` artifact.
static VIDEO_RENDER_CB: Mutex<Option<(usize, RenderFn)>> = Mutex::new(None);

/// Register an in-memory video renderer before `media_video_start`.
///
/// The callback runs on a Rust media thread and is handed a borrowed RGBA
/// buffer valid only for the duration of the call; copy before returning.
/// `len == 0` signals "no live frame" (peer camera off / track ended).
#[ffi_export]
pub fn media_video_set_render_cb(
    ctx: *const c_void,
    cb: unsafe extern "C" fn(*const c_void, *const u8, usize, u32, u32, u64),
) -> u8 {
    *VIDEO_RENDER_CB.lock().unwrap() = Some((ctx as usize, cb));
    0
}

#[ffi_export]
pub fn media_video_clear_render_cb() {
    *VIDEO_RENDER_CB.lock().unwrap() = None;
}

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

struct VideoSession {
    stop: Arc<AtomicBool>,
}

#[ffi_export]
pub fn media_video_start(ticket: char_p::Ref<'_>) -> char_p::Box {
    media_video_stop();
    video_error(""); // a stale error from the previous session must not fail this one
    let ticket = ticket.to_str().to_owned();
    let frame_path = media_path("video-frame.jpg");
    let temp_path = media_path("video-frame.jpg.tmp");
    let _ = std::fs::remove_file(&frame_path);
    let _ = std::fs::remove_file(&temp_path);
    let render: Box<dyn VideoRender> = match *VIDEO_RENDER_CB.lock().unwrap() {
        Some((ctx, cb)) => Box::new(CallbackRender { ctx, cb }),
        None => Box::new(DiskRender::new(&frame_path, &temp_path)),
    };
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let return_path = frame_path.to_string_lossy().into_owned();
    std::thread::spawn(move || {
        let Ok(runtime) = tokio::runtime::Runtime::new() else {
            video_error("video runtime creation failed");
            return;
        };
        runtime.block_on(video_loop(&ticket, render, thread_stop));
    });
    *VIDEO.lock().unwrap() = Some(VideoSession { stop });
    return_path.try_into().unwrap()
}

#[ffi_export]
pub fn media_video_last_error() -> char_p::Box {
    VIDEO_ERROR
        .get_or_init(|| Mutex::new(String::new()))
        .lock()
        .map(|error| error.clone())
        .unwrap_or_default()
        .try_into()
        .unwrap()
}

#[ffi_export]
pub fn media_video_stop() {
    if let Some(session) = VIDEO.lock().unwrap().take() {
        session.stop.store(true, Ordering::Relaxed);
    }
}

/// Disk artifact renderer: the fallback when no shell callback is registered.
struct DiskRender {
    frame_path: PathBuf,
    temp_path: PathBuf,
}

impl DiskRender {
    fn new(frame_path: &Path, temp_path: &Path) -> Self {
        Self {
            frame_path: frame_path.to_path_buf(),
            temp_path: temp_path.to_path_buf(),
        }
    }
}

impl VideoRender for DiskRender {
    fn present(&self, frame: VideoFrame) {
        let Ok(rgba) = frame.surface.into_rgba() else {
            return;
        };
        let mut jpeg = Vec::new();
        let encoder = jpeg_encoder::Encoder::new(&mut jpeg, 80);
        if encoder
            .encode(
                rgba.data(),
                rgba.width() as u16,
                rgba.height() as u16,
                jpeg_encoder::ColorType::Rgba,
            )
            .is_ok()
        {
            if std::fs::write(&self.temp_path, &jpeg).is_ok() {
                let _ = std::fs::rename(&self.temp_path, &self.frame_path);
            }
        } else {
            video_error("video JPEG encode failed");
        }
    }

    fn clear(&self) {
        let _ = std::fs::remove_file(&self.frame_path);
    }
}

/// In-memory renderer: hands decoded RGBA frames straight to the shell.
struct CallbackRender {
    ctx: usize,
    cb: RenderFn,
}

impl VideoRender for CallbackRender {
    fn present(&self, frame: VideoFrame) {
        let Ok(rgba) = frame.surface.into_rgba() else {
            return;
        };
        let data = rgba.data();
        let pts_ms = frame.timestamp.as_millis() as u64;
        unsafe {
            (self.cb)(
                self.ctx as *const c_void,
                data.as_ptr(),
                data.len(),
                rgba.width(),
                rgba.height(),
                pts_ms,
            );
        }
    }

    fn clear(&self) {
        unsafe { (self.cb)(self.ctx as *const c_void, std::ptr::null(), 0, 0, 0, 0) };
    }
}

async fn video_loop(ticket: &str, render: Box<dyn VideoRender>, stop: Arc<AtomicBool>) {
    let ticket = match ticket.parse::<LiveTicket>() {
        Ok(ticket) => ticket,
        Err(error) => {
            video_error(format!("ticket parse failed: {error}"));
            return;
        }
    };
    let live = match Live::from_env().await {
        Ok(live) => live.spawn(),
        Err(error) => {
            video_error(format!("live init failed: {error}"));
            return;
        }
    };
    let subscription = match live
        .subscribe(ticket.endpoint, &ticket.broadcast_name)
        .await
    {
        Ok(subscription) => subscription,
        Err(error) => {
            video_error(format!("video subscribe failed: {error}"));
            return;
        }
    };
    let broadcast = subscription.broadcast();
    // The publisher registers its video rendition only once the first camera
    // frame reaches the encoder (moq-media `VideoSource::Frames` derives the
    // catalog geometry from it), and a mic-first call may not switch the camera
    // on for a while. The first catalog is therefore audio-only or empty; wait
    // for the rendition instead of failing on that snapshot.
    while !broadcast.has_video() {
        if stop.load(Ordering::Relaxed) {
            live.shutdown().await;
            return;
        }
        tokio::time::sleep(STOP_POLL).await;
    }
    let track = match broadcast.video().await {
        Ok(track) => track,
        Err(error) => {
            video_error(format!("video track failed: {error}"));
            live.shutdown().await;
            return;
        }
    };
    track.enable_adaptation(subscription.signals().clone());
    while !stop.load(Ordering::Relaxed) {
        // `VideoTrack::recv` is a cancel-safe latest-frame slot, so bounding it
        // keeps hangup prompt and lets an idle track clear the picture.
        let frame = match tokio::time::timeout(FRAME_IDLE, track.recv()).await {
            Ok(Some(frame)) => frame,
            Ok(None) => break,
            Err(_) => {
                render.clear();
                continue;
            }
        };
        render.present(frame);
    }
    // Track ended or the session stopped: nothing is live any more.
    render.clear();
    live.shutdown().await;
}
