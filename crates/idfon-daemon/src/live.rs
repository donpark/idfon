//! Live-audio publish/subscribe over iroh-live, driven by daemon methods
//! (`media.live.*`). The daemon owns the Live endpoints; the CLI drives them
//! over IPC. Publishers stay alive in an in-memory registry until stopped —
//! live sessions are not persisted.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use crate::TransportMode;
use idfon_media::live::{listen_to_wav, LivePublisher};
use idfon_protocol::{ErrorCode, Request, Response};

static LIVE_PUBLISHERS: OnceLock<Mutex<HashMap<String, LivePublisher>>> = OnceLock::new();

fn publishers() -> &'static Mutex<HashMap<String, LivePublisher>> {
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
/// Params: `file` (required), `loop` (bool, default false), `name` (optional).
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
    let (publisher, ticket) = match LivePublisher::start(&path, loop_playback, &name, relay) {
        Ok(result) => result,
        Err(err) => return error(&request.id, method, format!("live publish failed: {err:#}")),
    };
    let id = format!("live-{}", name.trim_start_matches("idfon-live-"));
    publishers()
        .lock()
        .expect("live publishers poisoned")
        .insert(id.clone(), publisher);
    ok(
        &request.id,
        serde_json::json!({"id": id, "name": name, "ticket": ticket, "file": file, "loop": loop_playback,
            "wall_ms": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).expect("clock before epoch").as_millis() as u64}),
    )
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

/// `media.live.subscribe` — record a remote broadcast to a WAV file.
/// Params: `ticket` (required), `seconds` (default 15, capped at 600),
/// `out` (optional WAV path; defaults to a temp file).
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
    let out = match request
        .params
        .get("out")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
    {
        Some(path) => PathBuf::from(path),
        None => std::env::temp_dir().join(format!(
            "idfon-live-{}.wav",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock before epoch")
                .as_nanos()
        )),
    };
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
    let out = match request
        .params
        .get("out")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
    {
        Some(path) => PathBuf::from(path),
        None => std::env::temp_dir().join(format!(
            "idfon-call-{}.wav",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock before epoch")
                .as_nanos()
        )),
    };
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
