//! Live-audio publish/subscribe over iroh-live, driven by daemon methods
//! (`media.live.*`). The daemon owns the Live endpoints; the CLI drives them
//! over IPC. Publishers stay alive in an in-memory registry until stopped —
//! live sessions are not persisted.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use crate::TransportMode;
use idfon_media::live::{listen_to_wav, LivePublisher};
use idfon_media::video::{listen_to_h264, VideoPublisher};
use idfon_protocol::{ErrorCode, Request, Response};

/// A running file-source publisher, audio or video. Live sessions are not
/// persisted; entries live in an in-memory registry until stopped.
enum Publisher {
    Audio(LivePublisher),
    Video(VideoPublisher),
}

impl Publisher {
    fn stop(self) {
        match self {
            Publisher::Audio(publisher) => publisher.stop(),
            Publisher::Video(publisher) => publisher.stop(),
        }
    }
}

static LIVE_PUBLISHERS: OnceLock<Mutex<HashMap<String, Publisher>>> = OnceLock::new();

fn publishers() -> &'static Mutex<HashMap<String, Publisher>> {
    LIVE_PUBLISHERS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn error(id: &str, method: &str, message: impl Into<String>) -> Response {
    crate::error_response(
        id.to_string(),
        method,
        ErrorCode::InvalidRequest,
        message.into(),
        false,
    )
}

/// `media.live.publish` — publish a media file as a live broadcast.
/// Params: `file` (required), `loop` (bool, default false, audio only),
/// `name` (optional), `video` (bool, default false), `presets`
/// (optional video quality ladder, e.g. ["180p", "360p", "720p"]).
/// Result: `{id, ticket}` — the live ticket is the subscriber capability.
pub fn live_publish(request: &Request) -> Response {
    let method = &request.method;
    let Some(file) = request
        .params
        .get("file")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return error(&request.id, method, "file is required (mic source not supported yet)");
    };
    let loop_playback = request
        .params
        .get("loop")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let relay = request
        .params
        .get("relay")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(true);
    let name = request
        .params
        .get("name")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| {
            format!(
                "idfon-live-{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("clock before epoch")
                    .as_nanos()
            )
        });
    let path = PathBuf::from(file);
    if !path.is_file() {
        return error(&request.id, method, format!("file not found: {file}"));
    }
    let video = request
        .params
        .get("video")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let (publisher, ticket, kind) = if video {
        let presets = match video_presets(&request) {
            Ok(presets) => presets,
            Err(message) => return error(&request.id, method, message),
        };
        match VideoPublisher::start(&path, &name, relay, presets) {
            Ok((publisher, ticket)) => (Publisher::Video(publisher), ticket, "video"),
            Err(err) => return error(&request.id, method, format!("live publish failed: {err:#}")),
        }
    } else {
        match LivePublisher::start(&path, loop_playback, &name, relay) {
            Ok((publisher, ticket)) => (Publisher::Audio(publisher), ticket, "audio"),
            Err(err) => return error(&request.id, method, format!("live publish failed: {err:#}")),
        }
    };
    let id = format!("live-{}", name.trim_start_matches("idfon-live-"));
    publishers()
        .lock()
        .expect("live publishers poisoned")
        .insert(id.clone(), publisher);
    ok(
        &request.id,
        serde_json::json!({"id": id, "name": name, "ticket": ticket, "file": file, "kind": kind,
            "wall_ms": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).expect("clock before epoch").as_millis() as u64}),
    )
}

/// Parses the optional video quality ladder (`presets: ["180p", ...]`).
fn video_presets(request: &Request) -> Result<Vec<idfon_media::video::VideoPreset>, String> {
    use std::str::FromStr;
    match request.params.get("presets").and_then(serde_json::Value::as_array) {
        None => Ok(vec![
            idfon_media::video::VideoPreset::P180,
            idfon_media::video::VideoPreset::P360,
            idfon_media::video::VideoPreset::P720,
        ]),
        Some(values) => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .ok_or_else(|| "presets must be strings".to_string())
                    .and_then(|s| {
                        idfon_media::video::VideoPreset::from_str(s)
                            .map_err(|_| format!("unknown preset '{s}' (expected 180p, 360p, 720p, 1080p)"))
                    })
            })
            .collect(),
    }
}

/// `media.live.stop` — stop a publisher and remove it from the registry.
pub fn live_stop(request: &Request) -> Response {
    let Some(id) = request.params.get("id").and_then(serde_json::Value::as_str) else {
        return error(&request.id, &request.method, "id is required");
    };
    match publishers()
        .lock()
        .expect("live publishers poisoned")
        .remove(id)
    {
        Some(publisher) => publisher.stop(),
        None => {
            return crate::error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::InvalidRequest,
                "no such live publisher".into(),
                false,
            )
        }
    }
    ok(&request.id, serde_json::json!({"id": id, "stopped": true}))
}

/// `media.live.subscribe` — record a remote broadcast to a file.
/// Params: `ticket` (required), `seconds` (default 15, capped at 600),
/// `out` (optional path; defaults to a temp file), `relay` (bool), `video`
/// (bool, default false), `quality` ("low"|"mid"|"high"|"highest", video
/// only). Audio records WAV; video records Annex B H.264 (`.h264`),
/// playable with ffplay/mpv.
/// Blocking by design: the response arrives when the capture window ends.
pub fn live_subscribe(request: &Request) -> Response {
    let Some(ticket) = request
        .params
        .get("ticket")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return error(&request.id, &request.method, "ticket is required");
    };
    let seconds = request
        .params
        .get("seconds")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(15)
        .clamp(1, 600);
    let relay = request
        .params
        .get("relay")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(true);
    let video = request
        .params
        .get("video")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let default_ext = if video { "h264" } else { "wav" };
    let out = match request
        .params
        .get("out")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
    {
        Some(path) => PathBuf::from(path),
        None => std::env::temp_dir().join(format!(
            "idfon-live-{}.{default_ext}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock before epoch")
                .as_nanos()
        )),
    };
    if video {
        let quality = request
            .params
            .get("quality")
            .and_then(serde_json::Value::as_str)
            .map(|q| match q {
                "low" => Ok(idfon_media::video::Quality::Low),
                "mid" | "medium" => Ok(idfon_media::video::Quality::Mid),
                "high" => Ok(idfon_media::video::Quality::High),
                "highest" => Ok(idfon_media::video::Quality::Highest),
                other => Err(format!(
                    "unknown quality '{other}' (expected low, mid, high, highest)"
                )),
            })
            .transpose();
        let quality = match quality {
            Ok(quality) => quality,
            Err(message) => return error(&request.id, &request.method, message),
        };
        match listen_to_h264(ticket, &out, seconds, relay, quality) {
            Ok(stats) => ok(
                &request.id,
                serde_json::json!({
                    "out": stats.out,
                    "kind": "video",
                    "frames": stats.frames,
                    "bytes": stats.bytes,
                    "duration_ms": stats.duration_ms,
                    "subscribe_ms": stats.subscribe_ms,
                }),
            ),
            Err(err) => error(&request.id, &request.method, format!("live subscribe failed: {err:#}")),
        }
    } else {
        match listen_to_wav(ticket, &out, seconds, relay) {
        Ok(stats) => ok(
            &request.id,
            serde_json::json!({
                "out": out.display().to_string(),
                "duration_ms": stats.duration_ms,
                "packets": stats.packets,
                "arrival_jitter_ms": stats.arrival_jitter_ms,
                "wall_ms": stats.wall_ms,
                "subscribe_ms": stats.subscribe_ms,
                "startup_ms": stats.startup_ms,
                "max_gap_ms": stats.max_gap_ms,
                "stalls_over_100ms": stats.stalls_over_100ms,
                "missing_packets": stats.missing_packets,
                "prebuffer_ms": stats.prebuffer_ms,
            }),
        ),
        Err(err) => error(&request.id, &request.method, format!("live subscribe failed: {err:#}")),
        }
    }
}

/// `media.live.dial` — 1:1 session-scoped stream to a peer. The audio is
/// published on the peer connection only; no ticket exists. Params: `file`
/// (required), `loop` (bool), `seconds` (optional hold cap), `relay` (bool).
/// Blocking: returns when the peer hangs up or the cap expires.
pub fn live_dial(request: &Request, peer_addr: &str) -> Response {
    let method = &request.method;
    let Some(file) = request
        .params
        .get("file")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return error(&request.id, method, "file is required");
    };
    let loop_playback = request
        .params
        .get("loop")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let seconds = request.params.get("seconds").and_then(serde_json::Value::as_u64);
    let relay = request
        .params
        .get("relay")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(true);
    let path = PathBuf::from(file);
    if !path.is_file() {
        return error(&request.id, method, format!("file not found: {file}"));
    }
    let video = request
        .params
        .get("video")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    if video {
        if loop_playback {
            return error(&request.id, method, "loop is not supported for video dial");
        }
        return match idfon_media::video::dial_to_peer(&path, peer_addr, seconds, relay) {
            Ok(held_ms) => ok(
                &request.id,
                serde_json::json!({"held_ms": held_ms, "session_scoped": true, "kind": "video"}),
            ),
            Err(err) => error(&request.id, method, format!("live dial failed: {err:#}")),
        };
    }
    match idfon_media::live::stream_to_peer(&path, loop_playback, peer_addr, seconds, relay) {
        Ok(held_ms) => ok(
            &request.id,
            serde_json::json!({"held_ms": held_ms, "session_scoped": true}),
        ),
        Err(err) => error(&request.id, method, format!("live dial failed: {err:#}")),
    }
}

/// `media.live.answer` — wait for an inbound 1:1 call and record it.
/// Params: `out` (optional WAV path), `seconds` (capture window, default
/// 60, cap 600), `wait` (seconds to wait for a caller, default 120, cap
/// 600), `from` (optional caller endpoint id). Blocking. Requires the real
/// iroh transport: the call rides the daemon's transport endpoint via a
/// side-channel ALPN for the duration.
pub fn live_answer(
    request: &Request,
    transport: &std::sync::Arc<TransportMode>,
    identity_id: &str,
) -> Response {
    let method = &request.method;
    let Some(transport) = transport.current_transport(identity_id) else {
        return error(&request.id, method, "no transport for identity");
    };
    let seconds = request
        .params
        .get("seconds")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(60)
        .clamp(1, 600);
    let wait = request
        .params
        .get("wait")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(120)
        .clamp(1, 600);
    let from = request
        .params
        .get("from")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty());
    let video = request
        .params
        .get("video")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let default_ext = if video { "h264" } else { "wav" };
    let out = match request
        .params
        .get("out")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
    {
        Some(path) => PathBuf::from(path),
        None => std::env::temp_dir().join(format!(
            "idfon-call-{}.{default_ext}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock before epoch")
                .as_nanos()
        )),
    };
    if video {
        let quality = request
            .params
            .get("quality")
            .and_then(serde_json::Value::as_str)
            .map(|q| match q {
                "low" => Ok(idfon_media::video::Quality::Low),
                "mid" | "medium" => Ok(idfon_media::video::Quality::Mid),
                "high" => Ok(idfon_media::video::Quality::High),
                "highest" => Ok(idfon_media::video::Quality::Highest),
                other => Err(format!(
                    "unknown quality '{other}' (expected low, mid, high, highest)"
                )),
            })
            .transpose();
        let quality = match quality {
            Ok(quality) => quality,
            Err(message) => return error(&request.id, method, message),
        };
        return match idfon_media::video::answer_to_h264(transport, &out, seconds, wait, from, quality)
        {
            Ok(stats) => ok(
                &request.id,
                serde_json::json!({
                    "out": stats.out,
                    "kind": "video",
                    "frames": stats.frames,
                    "bytes": stats.bytes,
                    "duration_ms": stats.duration_ms,
                    "subscribe_ms": stats.subscribe_ms,
                }),
            ),
            Err(err) => error(&request.id, method, format!("live answer failed: {err:#}")),
        };
    }
    match idfon_media::live::answer_to_wav(transport, &out, seconds, wait, from) {
        Ok(stats) => ok(
            &request.id,
            serde_json::json!({
                "out": out.display().to_string(),
                "duration_ms": stats.duration_ms,
                "packets": stats.packets,
                "arrival_jitter_ms": stats.arrival_jitter_ms,
                "wall_ms": stats.wall_ms,
                "subscribe_ms": stats.subscribe_ms,
                "startup_ms": stats.startup_ms,
                "max_gap_ms": stats.max_gap_ms,
                "stalls_over_100ms": stats.stalls_over_100ms,
                "missing_packets": stats.missing_packets,
                "prebuffer_ms": stats.prebuffer_ms,
            }),
        ),
        Err(err) => error(&request.id, method, format!("live answer failed: {err:#}")),
    }
}

/// `media.live.publishers` — list running publishers.
pub fn live_publishers(request: &Request) -> Response {
    let ids: Vec<String> = publishers()
        .lock()
        .expect("live publishers poisoned")
        .keys()
        .cloned()
        .collect();
    ok(&request.id, serde_json::json!({"ids": ids}))
}

fn ok(id: &str, result: serde_json::Value) -> Response {
    Response {
        version: idfon_protocol::PROTOCOL_VERSION,
        id: id.to_string(),
        ok: true,
        body: idfon_protocol::ResponseBody::Success {
            operation: String::new(),
            result,
        },
    }
}
