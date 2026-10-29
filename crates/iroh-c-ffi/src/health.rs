//! Health-check runner (docs/media-adaptation.md §B2.2).
//!
//! The shell-agnostic half of the seam: sample the live session's network
//! signals over a check window and emit `idfon_media::health::Progress` JSON
//! through a callback. Shells own progress presentation and action buttons;
//! this module only traces.

use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use iroh::endpoint::Connection;
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointAddr};
use iroh_live::Live;
use moq_media::net::NetworkSignals;
use safer_ffi::prelude::*;
use tokio::sync::watch;

use idfon_media::health::{
    decimate, AudioArrival, CallRecord, Context, Leg, NetPoint, PathSwitch, Progress, Report,
    Sample, TIMELINE_CAP,
};

/// The health-check ALPN: one request, one `Leg` reply, on the call's own
/// endpoint (docs/media-adaptation.md §B2.2).
pub const HEALTH_ALPN: &[u8] = b"idfon-health/1";

static SIGNALS: Mutex<Option<watch::Receiver<NetworkSignals>>> = Mutex::new(None);
static CHANNELS: AtomicU64 = AtomicU64::new(1);
/// Routers serving [`HEALTH_ALPN`], one per session endpoint. A call runs
/// two endpoints in one process (publish and subscribe legs); each keeps its
/// own accept side alive.
static ROUTERS: Mutex<Vec<(iroh::EndpointId, Router)>> = Mutex::new(Vec::new());
/// The endpoint of the attached session: where a merged check dials out.
static ENDPOINT: Mutex<Option<Endpoint>> = Mutex::new(None);
/// The attached session's connection: what the per-call record reads path
/// state (direct/relay, path switches) from.
static CONN: Mutex<Option<Connection>> = Mutex::new(None);

/// Serve the health ALPN on the session's endpoint, alongside MoQ. Per
/// endpoint and idempotent; routers live as long as their endpoint.
pub(crate) fn ensure_served(live: &Live) {
    let mut routers = ROUTERS.lock().unwrap_or_else(|poison| poison.into_inner());
    if routers.iter().any(|(id, _)| *id == live.endpoint().id()) {
        return;
    }
    let endpoint = live.endpoint().clone();
    let builder = live.register_protocols(Router::builder(endpoint.clone()));
    let router = builder.accept(HEALTH_ALPN, Arc::new(HealthProtocol)).spawn();
    routers.push((live.endpoint().id(), router));
}

/// Attach the live session's connection and signals so checks and the
/// per-call record can sample them. Call it when a subscription is
/// established; the last one wins per call, and a re-attach (the re-subscribe
/// loop) keeps the record accumulating rather than starting a new one.
pub(crate) fn attach(live: &Live, conn: &Connection, signals: watch::Receiver<NetworkSignals>) {
    ensure_served(live);
    *ENDPOINT.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(live.endpoint().clone());
    *CONN.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(conn.clone());
    *SIGNALS.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(signals);
    start_call_sampling();
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

// --- Per-call quality record (docs/media-adaptation.md §C1) --------------

/// The last ended call's record as JSON (`idfon_media::health::CallRecord`),
/// for shells to ship to `Diag` at hangup. Empty before any call has ended.
static LAST_REPORT: Mutex<String> = Mutex::new(String::new());

/// What one call accumulates between [`start_call_sampling`] and
/// [`finish_call_sampling`].
struct CallSampler {
    stop: std::sync::Arc<AtomicBool>,
    started: Instant,
    started_wall_ms: u64,
    timeline: std::sync::Arc<Mutex<Vec<NetPoint>>>,
    switches: std::sync::Arc<Mutex<Vec<PathSwitch>>>,
    audio: std::sync::Arc<Mutex<AudioArrival>>,
    video_seen: std::sync::Arc<AtomicBool>,
    underruns_at_start: u64,
}

static CALL: Mutex<Option<CallSampler>> = Mutex::new(None);

/// The attached connection's selected path: id and relay flag.
fn selected_path() -> Option<(String, bool)> {
    let conn = CONN
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .clone()?;
    let paths = conn.paths();
    let selected = paths.iter().find(|p| p.is_selected())?;
    Some((format!("{:?}", selected.id()), selected.is_relay()))
}

/// Sample the attached session for the length of a call. Starts with
/// [`attach`]; the record is produced by [`finish_call_sampling`]. A re-attach
/// (the re-subscribe loop) keeps the same record accumulating — only a fresh
/// [`start_call_sampling`] with no record running begins one.
fn start_call_sampling() {
    let mut slot = CALL.lock().unwrap_or_else(|poison| poison.into_inner());
    if slot.is_some() {
        return;
    }
    let stop = std::sync::Arc::new(AtomicBool::new(false));
    let timeline = std::sync::Arc::new(Mutex::new(Vec::new()));
    let switches = std::sync::Arc::new(Mutex::new(Vec::new()));
    let last_path = std::sync::Arc::new(Mutex::new(None));
    let audio = std::sync::Arc::new(Mutex::new(AudioArrival::new()));
    let video_seen = std::sync::Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let thread_timeline = timeline.clone();
    let thread_switches = switches.clone();
    let thread_last_path = last_path.clone();
    let thread_video = video_seen.clone();
    let started = Instant::now();
    std::thread::spawn(move || {
        while !thread_stop.load(Ordering::Relaxed) {
            std::thread::sleep(Duration::from_millis(500));
            // Sources are re-read each tick: a return-leg re-invite swaps the
            // subscription (and with it SIGNALS/CONN) mid-call.
            let Some(signals) = SIGNALS
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .clone()
            else {
                continue;
            };
            let sample = take_sample(&signals);
            let t_ms = started.elapsed().as_millis() as u64;
            if crate::media::video_enabled() {
                thread_video.store(true, Ordering::Relaxed);
            }
            // Path state comes from the connection each tick: a path switch
            // mid-call is a timeline event (#22's handover evidence).
            let path = selected_path();
            let relay = path
                .as_ref()
                .or(thread_last_path.lock().unwrap_or_else(|p| p.into_inner()).as_ref())
                .map(|(_, relay)| *relay)
                .unwrap_or(false);
            if let Some(path) = path {
                let mut last = thread_last_path.lock().unwrap_or_else(|p| p.into_inner());
                if last.as_ref() != Some(&path) {
                    thread_switches
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .push(PathSwitch {
                            t_ms,
                            path: path.0.clone(),
                            relay: path.1,
                        });
                    *last = Some(path);
                }
            }
            thread_timeline
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .push(NetPoint {
                    t_ms,
                    rtt_ms: sample.rtt_ms,
                    min_rtt_ms: sample.min_rtt_ms,
                    loss_pct: sample.loss_pct,
                    goodput_kbps: sample.goodput_kbps,
                    relay,
                });
        }
    });
    *slot = Some(CallSampler {
        stop,
        started,
        started_wall_ms: SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|since| since.as_millis() as u64)
            .unwrap_or(0),
        timeline,
        switches,
        audio,
        video_seen,
        underruns_at_start: crate::media::underruns(),
    });
}

/// Feed one decoded frame into the running call's audio fold (the decode
/// loop's pts observations). Time runs from the record's own start, so a
/// second subscribe leg (return-leg re-invite) keeps one timeline. No-op
/// when no call is sampling.
pub(crate) fn note_frame(pts_us: u64, pts_gap_us: u64) {
    let call = CALL.lock().unwrap_or_else(|poison| poison.into_inner());
    if let Some(call) = call.as_ref() {
        let arrival_us = call.started.elapsed().as_micros() as u64;
        call.audio
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .record(arrival_us, pts_us, pts_gap_us);
    }
}

/// Fold the call's accumulators into the record (the same shape whether the
/// call is still running or just ended).
fn build_record(call: &CallSampler) -> CallRecord {
    let underruns = crate::media::underruns().saturating_sub(call.underruns_at_start);
    let points = call
        .timeline
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .clone();
    let samples: Vec<Sample> = points
        .iter()
        .map(|p| Sample {
            rtt_ms: p.rtt_ms,
            min_rtt_ms: p.min_rtt_ms,
            loss_pct: p.loss_pct,
            goodput_kbps: p.goodput_kbps,
        })
        .collect();
    let context = Context {
        video_on: call.video_seen.load(Ordering::Relaxed),
        stereo: CHANNELS.load(Ordering::Relaxed) > 1,
    };
    let audio = call
        .audio
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .stats(underruns);
    CallRecord {
        started_ms: call.started_wall_ms,
        duration_ms: call.started.elapsed().as_millis() as u64,
        context,
        audio,
        report: Report::one_sided(Leg::fold(&samples, underruns), context),
        timeline: decimate(&points, TIMELINE_CAP),
        path_switches: call
            .switches
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clone(),
    }
}

/// Produce the per-call quality record at hangup: fold the call's timeline,
/// path switches and audio stats; log it (telemetry); keep it for
/// [`media_health_last_report`] so the shell can ship it to `Diag`.
pub(crate) fn finish_call_sampling() {
    let Some(call) = CALL.lock().unwrap_or_else(|poison| poison.into_inner()).take() else {
        return;
    };
    call.stop.store(true, Ordering::Relaxed);
    let json = serde_json::to_string(&build_record(&call)).unwrap_or_default();
    tracing::info!(target: "quality", "per-call record: {json}");
    eprintln!("[health] per-call record: {json}");
    *LAST_REPORT.lock().unwrap_or_else(|poison| poison.into_inner()) = json;
}

/// The last ended call's record JSON (`idfon_media::health::CallRecord`),
/// taken (and cleared) so one record ships exactly once. Empty when no call
/// has ended since the last read.
#[ffi_export]
pub fn media_health_last_report() -> char_p::Box {
    std::mem::take(&mut *LAST_REPORT.lock().unwrap_or_else(|poison| poison.into_inner()))
        .try_into()
        .unwrap()
}

/// One probe request: sample for `probe_ms` and answer with one `Leg`.
#[derive(serde::Serialize, serde::Deserialize)]
struct Probe {
    probe_ms: u64,
}

#[derive(Debug)]
struct HealthProtocol;

impl ProtocolHandler for HealthProtocol {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let (mut send, mut recv) = connection
            .accept_bi()
            .await
            .map_err(AcceptError::from_err)?;
        let request = recv
            .read_to_end(4_096)
            .await
            .map_err(AcceptError::from_err)?;
        let probe: Probe = serde_json::from_slice(&request).map_err(AcceptError::from_err)?;
        let leg = sample_leg(Duration::from_millis(probe.probe_ms.clamp(1, 60_000))).await;
        let json = serde_json::to_vec(&leg).map_err(AcceptError::from_err)?;
        send.write_all(&json).await.map_err(AcceptError::from_err)?;
        send.finish().map_err(AcceptError::from_err)?;
        Ok(())
    }
}

/// Sample this endpoint's downlink over `window`, the responder half.
async fn sample_leg(window: Duration) -> Leg {
    let Some(signals) = SIGNALS
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .clone()
    else {
        return Leg::default();
    };
    let start = Instant::now();
    let underruns_at_start = crate::media::underruns();
    let mut samples = Vec::new();
    while start.elapsed() < window {
        tokio::time::sleep(Duration::from_millis(250).min(window)).await;
        samples.push(take_sample(&signals));
    }
    let underruns = crate::media::underruns().saturating_sub(underruns_at_start);
    Leg::fold(&samples, underruns)
}

/// Ask the far end for its leg over the health ALPN, on the session endpoint.
async fn fetch_remote_leg(endpoint: Endpoint, addr: EndpointAddr, probe_ms: u64) -> Option<Leg> {
    let connection = endpoint.connect(addr, HEALTH_ALPN).await.ok()?;
    let (mut send, mut recv) = connection.open_bi().await.ok()?;
    let request = serde_json::to_vec(&Probe { probe_ms }).ok()?;
    send.write_all(&request).await.ok()?;
    send.finish().ok()?;
    let json = recv.read_to_end(16_384).await.ok()?;
    serde_json::from_slice(&json).ok()
}

fn session_endpoint() -> Option<Endpoint> {
    ENDPOINT
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .clone()
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
    run_check(ctx, cb, duration_ms, None)
}

/// The bi-directional check: like [`media_health_check`], and the far end
/// (its iroh endpoint address as JSON) samples its own downlink over the
/// same window on the health ALPN. The `done` report merges both legs.
/// Returns 0 when started, 1 when no live session is attached, 2 when the
/// address does not parse.
#[ffi_export]
pub fn media_health_check_remote(
    ctx: *const c_void,
    cb: unsafe extern "C" fn(*const c_void, *const u8, usize, u8),
    duration_ms: u64,
    peer_addr: char_p::Ref<'_>,
) -> u8 {
    let Some(endpoint) = session_endpoint() else {
        return 1;
    };
    let Ok(addr) = serde_json::from_str::<EndpointAddr>(peer_addr.to_str()) else {
        return 2;
    };
    run_check(ctx, cb, duration_ms, Some((endpoint, addr)))
}

/// The shell-friendly bi-directional check: the far end is named by its
/// `LiveTicket` (what call setup already holds) instead of a raw address.
/// Returns 0 when started, 1 when no live session is attached, 2 when the
/// ticket does not parse.
#[ffi_export]
pub fn media_health_check_ticket(
    ctx: *const c_void,
    cb: unsafe extern "C" fn(*const c_void, *const u8, usize, u8),
    duration_ms: u64,
    peer_ticket: char_p::Ref<'_>,
) -> u8 {
    let Some(endpoint) = session_endpoint() else {
        return 1;
    };
    let Ok(ticket) = peer_ticket.to_str().parse::<iroh_live::ticket::LiveTicket>() else {
        return 2;
    };
    run_check(ctx, cb, duration_ms, Some((endpoint, ticket.endpoint)))
}

fn run_check(
    ctx: *const c_void,
    cb: unsafe extern "C" fn(*const c_void, *const u8, usize, u8),
    duration_ms: u64,
    remote: Option<(Endpoint, EndpointAddr)>,
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
        // The far leg samples its own window on request; ask first so both
        // windows run concurrently.
        let runtime = remote.as_ref().map(|_| {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("health check runtime")
        });
        let remote_leg = runtime.as_ref().and_then(|rt| {
            let (endpoint, addr) = remote.clone().unwrap();
            Some(rt.spawn(async move {
                fetch_remote_leg(endpoint, addr, duration.as_millis() as u64).await
            }))
        });
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
        let report = match (remote_leg, runtime) {
            (Some(handle), Some(rt)) => match rt.block_on(handle) {
                Ok(Some(remote)) => Report::merged(local, remote, context),
                _ => Report::one_sided(local, context),
            },
            _ => Report::one_sided(local, context),
        };
        emit(&Progress::Done { report });
    });
    0
}
