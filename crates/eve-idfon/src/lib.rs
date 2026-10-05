use std::{
    collections::{HashMap, VecDeque},
    io::ErrorKind,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use chrono::{DateTime, Utc};
use clap::{Parser, Subcommand};
use ed25519_dalek::SigningKey;
use idfon_core::transport::{IrohTransport, MessageTransport, TransportError};
use idfon_core::{
    peer_id, sign_message, sign_message_with_ticket, issue_capability_ticket_with_voice,
    verify_capability_ticket, verify_message, AuthError,
};
use idfon_protocol::{
    AckStatus, Capability, CapabilityTicket, MessageAck, MessageContent, MessageEnvelope,
    VoiceMode, VoiceRoute, MAX_FRAME_BYTES,
};
use iroh::{endpoint::presets, protocol::Router, Endpoint, EndpointAddr, EndpointId};
use iroh_blobs::{store::fs::FsStore, ticket::BlobTicket, BlobsProtocol, ALPN as BLOBS_ALPN};
use serde::{Deserialize, Serialize};
use tracing::Instrument;

pub mod deltas;
pub mod live;
pub mod live_audio;
pub mod records;
pub mod rooms;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::UnixListener,
    sync::{mpsc, Mutex, RwLock},
};

const IPC_MAX_FRAME_BYTES: usize = MAX_FRAME_BYTES;
const MAX_MESSAGES_PER_PEER_PER_MINUTE: usize = 120;
const MAX_TARGETS: usize = 4096;
const MAX_SEEN_MESSAGES: usize = 10_000;
const MAX_LIVE_PUBLISHERS: usize = 8;
const MAX_BLOB_BYTES: usize = 8 * 1024 * 1024;
const DEFAULT_LIVE_TTL_SECS: u64 = 3600;
static NEXT_REPLY_ID: AtomicU64 = AtomicU64::new(1);
/// A random token unique to this process. Holder-generated message ids used to
/// be a bare in-process counter (`eve_reply_1`, `eve_reply_2`, …), so restarting
/// the holder reused ids. Receivers that dedupe on message id — the Apple apps
/// do exactly that — then silently dropped a new message that happened to reuse
/// a seen id, which is how a fresh contact invite went missing. The per-process
/// token makes the ids globally unique across restarts.
static PROCESS_TOKEN: std::sync::OnceLock<String> = std::sync::OnceLock::new();

fn next_message_id(prefix: &str) -> String {
    use getrandom::rand_core::Rng as _;
    let token = PROCESS_TOKEN.get_or_init(|| {
        let mut bytes = [0u8; 8];
        getrandom::rand_core::UnwrapErr(getrandom::SysRng).fill_bytes(&mut bytes);
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    });
    format!(
        "{prefix}{token}_{:x}",
        NEXT_REPLY_ID.fetch_add(1, Ordering::Relaxed)
    )
}

#[derive(Parser)]
#[command(
    name = "eve-idfon",
    about = "idfon ingress channel endpoint holder"
)]
struct Cli {
    /// Hex Ed25519 key file. `EVE_IDFON_KEY` is used if unset.
    #[arg(long, global = true, value_name = "FILE")]
    key_file: Option<PathBuf>,
    /// Opaque agent/channel metadata (JSON): the live-call handler config and
    /// the voice routing advertised on minted tickets. Absent = a text-only
    /// holder (`voice.mode = client-cascade`).
    #[arg(long, global = true, value_name = "FILE")]
    live_config: Option<PathBuf>,
    #[command(subcommand)]
    mode: Mode,
}

#[derive(Subcommand)]
enum Mode {
    /// Own an idfon endpoint and bridge message turns over a Unix socket.
    Serve {
        #[arg(long, value_name = "PATH")]
        socket: PathBuf,
        /// Permit only these verified sender peer IDs. Repeat for multiple peers.
        #[arg(long = "allow", value_name = "PEER_ID")]
        allow: Vec<String>,
        /// File of additional allowed sender peer IDs, one per line, reloaded
        /// while running. Lets a provisioner admit a caller after startup.
        #[arg(long, value_name = "FILE")]
        allow_file: Option<PathBuf>,
        /// Permit an ephemeral identity when no key file or environment key exists.
        #[arg(long)]
        ephemeral: bool,
        /// Local cache for blobs fetched from incoming blob tickets.
        #[arg(long, default_value = "blobs")]
        blob_dir: PathBuf,
        /// JSON capability ticket to attach to outbound replies.
        #[arg(long, value_name = "FILE")]
        reply_ticket_file: Option<PathBuf>,
        /// Stop abandoned live publishers after this many seconds.
        #[arg(long, default_value_t = DEFAULT_LIVE_TTL_SECS)]
        live_ttl_secs: u64,
    },
    /// Issue a holder-signed message.receive ticket for initial provisioning.
    Ticket {
        #[arg(long, value_name = "PEER_ID")]
        subject: String,
        /// Additional grant names to include alongside message.receive.
        #[arg(long = "capability")]
        capabilities: Vec<String>,
        #[arg(long)]
        expires_at: Option<String>,
        #[arg(long)]
        ticket_id: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum IpcFrame {
    #[serde(rename = "turn.in")]
    TurnIn {
        message_id: String,
        peer_id: String,
        endpoint_id: String,
        idempotency_key: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation: Option<String>,
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        blob_ticket: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        size_bytes: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        a2a_depth: Option<u8>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        capabilities: Option<Vec<String>>,
        /// Provenance for turns injected by the holder rather than a real
        /// client message (e.g. a live-call delegation). Reaches Eve as a
        /// distinct auth attribute so approval/F10 policies can tell it apart.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source: Option<String>,
    },
    #[serde(rename = "reply.out")]
    ReplyOut {
        in_reply_to: String,
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        idempotency_key: Option<String>,
    },
    #[serde(rename = "reply.ack")]
    ReplyAck {
        in_reply_to: String,
        message_id: String,
        status: String,
    },
    #[serde(rename = "status.out")]
    StatusOut {
        request_id: String,
        in_reply_to: String,
        event: String,
        data: serde_json::Value,
    },
    #[serde(rename = "status.in")]
    StatusIn {
        message_id: String,
        peer_id: String,
        endpoint_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation: Option<String>,
        event: String,
        data: serde_json::Value,
    },
    #[serde(rename = "status.ack")]
    StatusAck {
        request_id: String,
        in_reply_to: String,
        message_id: String,
        event: String,
    },
    #[serde(rename = "input.out")]
    InputOut {
        request_id: String,
        peer_id: String,
        endpoint_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation: Option<String>,
        requests: serde_json::Value,
    },
    #[serde(rename = "input.in")]
    InputIn {
        message_id: String,
        peer_id: String,
        endpoint_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation: Option<String>,
        responses: serde_json::Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        capabilities: Option<Vec<String>>,
    },
    #[serde(rename = "input.ack")]
    InputAck {
        request_id: String,
        message_id: String,
        status: String,
    },
    #[serde(rename = "peer.send")]
    PeerSendOut {
        request_id: String,
        peer_id: String,
        endpoint_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation: Option<String>,
        text: String,
        capability_ticket: serde_json::Value,
        #[serde(default)]
        a2a_depth: u8,
    },
    #[serde(rename = "peer.ack")]
    PeerSendAck {
        request_id: String,
        message_id: String,
        status: String,
    },
    #[serde(rename = "blob.fetch")]
    BlobFetch { request_id: String, ticket: String },
    #[serde(rename = "blob.result")]
    BlobResult {
        request_id: String,
        bytes_base64: String,
        size_bytes: u64,
    },
    #[serde(rename = "blob.put")]
    BlobPut {
        request_id: String,
        bytes_base64: String,
    },
    #[serde(rename = "blob.put.result")]
    BlobPutResult {
        request_id: String,
        ticket: String,
        size_bytes: u64,
    },
    #[serde(rename = "records.drain")]
    RecordsDrain {
        request_id: String,
        peer_id: String,
        turn_id: String,
    },
    #[serde(rename = "records.drain.result")]
    RecordsDrainResult {
        request_id: String,
        records: Vec<serde_json::Value>,
    },
    #[serde(rename = "stream.append")]
    StreamAppend {
        request_id: String,
        /// Peer the delta belongs to, so a live voice backend can route it to
        /// the call's TTS (absent on older bridges).
        #[serde(default)]
        peer_id: Option<String>,
        turn_id: String,
        step_index: u64,
        sequence: u64,
        text: String,
    },
    #[serde(rename = "stream.append.result")]
    StreamAppendResult {
        request_id: String,
        accepted: bool,
    },
    /// Agent-produced PCM (s16le base64) for the active call's return leg.
    #[serde(rename = "audio.append")]
    AudioAppend {
        request_id: String,
        peer_id: String,
        pcm_base64: String,
    },
    #[serde(rename = "audio.append.result")]
    AudioAppendResult {
        request_id: String,
        accepted: bool,
    },
    /// Holder → bridge: one caller PCM frame for the live audio stream
    /// (s16le base64). The bridge fans it out to SSE subscribers.
    #[serde(rename = "audio.frame")]
    AudioFrameOut { peer_id: String, pcm_base64: String },
    #[serde(rename = "live.publish")]
    LivePublish {
        request_id: String,
        path: String,
        #[serde(default)]
        loop_playback: bool,
        name: String,
        #[serde(default)]
        relay: bool,
        #[serde(default)]
        video: bool,
        quality: Option<String>,
    },
    #[serde(rename = "live.publish.result")]
    LivePublishResult {
        request_id: String,
        id: String,
        ticket: String,
    },
    #[serde(rename = "live.stop")]
    LiveStop { request_id: String, id: String },
    #[serde(rename = "live.stop.result")]
    LiveStopResult { request_id: String, id: String },
    /// Mint a fresh, subject-bound capability ticket for `subject` using the
    /// holder's own key, and return it with the holder's endpoint address
    /// (the "business card" the agent hands out, per intro).
    #[serde(rename = "ticket.issue")]
    TicketIssue {
        request_id: String,
        subject: String,
        #[serde(default)]
        capabilities: Vec<String>,
    },
    #[serde(rename = "ticket.issue.result")]
    TicketIssueResult {
        request_id: String,
        ticket: serde_json::Value,
        endpoint_addr: serde_json::Value,
    },
    #[serde(rename = "error")]
    Error { code: String, message: String },
}

#[derive(Debug, Clone)]
pub struct ReplyTarget {
    pub peer_id: String,
    pub endpoint_id: String,
    pub conversation: Option<String>,
    pub a2a_depth: Option<u8>,
    /// Set for a turn delegated from a live call: the reply text is also fed
    /// back to the live session as `(delegation_id, spoken_text)` so the
    /// voice model can say the result.
    pub live_commentary: Option<(String, mpsc::UnboundedSender<(String, String)>)>,
    /// Voice-injected turn: speak the reply to the live session only, never
    /// post a second (text) copy to the caller's chat. The `IDFON-CALL/1`
    /// transcript the holder sends is the single record.
    pub live_only: bool,
    /// Correlation id read from the inbound message; echoed onto replies and
    /// status so the whole exchange joins under one trace.
    pub trace: Option<String>,
}

pub type Targets = Arc<Mutex<HashMap<String, ReplyTarget>>>;
type Seen = Arc<Mutex<HashMap<(String, String), String>>>;
type RateLimits = Arc<Mutex<HashMap<String, VecDeque<Instant>>>>;
type LivePublishers = Arc<Mutex<HashMap<String, LivePublisherEntry>>>;

enum LivePublisherKind {
    Audio(idfon_media::live::LivePublisher),
    Video(idfon_media::video::VideoPublisher),
}

impl LivePublisherKind {
    fn stop(self) {
        match self {
            Self::Audio(publisher) => publisher.stop(),
            Self::Video(publisher) => publisher.stop(),
        }
    }
}

struct LivePublisherEntry {
    publisher: LivePublisherKind,
    expires_at: Instant,
}

/// Run the holder. `live_registry` is populated by the composition root with
/// the live-call handlers this build ships; the generic platform build
/// registers none.
pub async fn run(live_registry: live::LiveCallRegistry) -> Result<()> {
    // iroh needs an explicit process-default rustls provider when multiple
    // provider features are unified in the binary.
    let _ = rustls::crypto::ring::default_provider().install_default();
    // Holder diagnostics go to /tmp/idfon-holder-<pid>.log via the shared
    // subscriber; IDFON_LOG/RUST_LOG/IROH_C_LOG control the filter (default
    // info). Essential for debugging silent subscription stalls on the
    // live-call return leg.
    idfon_telemetry::init_file(
        "eve-idfon",
        &PathBuf::from(format!("/tmp/idfon-holder-{}.log", std::process::id())),
        "info",
    );
    let cli = Cli::parse();
    let key_file = cli.key_file;
    let live_config = cli.live_config;
    match cli.mode {
        Mode::Serve {
            socket,
            allow,
            allow_file,
            ephemeral,
            blob_dir,
            reply_ticket_file,
            live_ttl_secs,
        } => {
            let key = load_key(key_file.as_deref(), ephemeral)?;
            let reply_ticket = reply_ticket_file
                .map(|path| load_ticket(&path))
                .transpose()?;
            let live_params = load_live_params(live_config.as_deref())?;
            serve(
                socket,
                allow,
                allow_file,
                key,
                blob_dir,
                reply_ticket,
                live_ttl_secs,
                Arc::new(live_registry),
                live_params,
            )
            .await
        }
        Mode::Ticket {
            subject,
            capabilities,
            expires_at,
            ticket_id,
        } => {
            let key = load_key(key_file.as_deref(), false)?;
            let live_params = load_live_params(live_config.as_deref())?;
            let ticket_id = ticket_id.unwrap_or_else(|| format!("eve-ticket-{}", now_seconds()));
            let voice = voice_route_from_live_params(&live_params);
            if voice.mode == VoiceMode::Delegated {
                admit_delegate_caller(&live_params, &subject);
            }
            let mut grants = vec![Capability::MessageReceive];
            grants.extend(capabilities.into_iter().map(Capability::new));
            println!(
                "{}",
                serde_json::to_string(&issue_capability_ticket_with_voice(
                    &key,
                    Some(subject),
                    None,
                    grants,
                    expires_at,
                    ticket_id,
                    Some(voice),
                ))?
            );
            Ok(())
        }
    }
}

fn load_live_params(path: Option<&Path>) -> Result<serde_json::Value> {
    match path {
        Some(path) => Ok(serde_json::from_slice(
            &std::fs::read(path).with_context(|| format!("read live config {}", path.display()))?,
        )
        .with_context(|| format!("parse live config {}", path.display()))?),
        None => Ok(serde_json::Value::Null),
    }
}

/// The voice routing this holder advertises on every ticket it mints. An
/// explicit `voice_route` block in the live config wins (named `voice_route`
/// because `voice` is the live session's voice id). Otherwise a holder with a
/// live config advertises `native-duplex` (it opted into a live-call handler);
/// a holder with no live config advertises `client-cascade` (its agent speaks
/// text and the caller supplies on-device STT/TTS).
/// When a delegated voice route is configured with a local delegate allow-file,
/// admit `subject` (a caller) there so a call can dial the delegate. The
/// delegate's holder reloads its allow-file while running.
fn admit_delegate_caller(params: &serde_json::Value, subject: &str) {
    if let Some(path) = params
        .get("voice_delegate_allow_file")
        .and_then(|value| value.as_str())
        .filter(|path| !path.is_empty())
    {
        admit_caller_to(path, subject);
    }
}

/// Append `subject` to a holder allow-file (idempotent).
fn admit_caller_to(path: &str, subject: &str) {
    if subject.is_empty() {
        return;
    }
    let already = std::fs::read_to_string(path)
        .map(|text| text.lines().any(|line| line.trim() == subject))
        .unwrap_or(false);
    if already {
        return;
    }
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        use std::io::Write as _;
        let _ = writeln!(file, "{subject}");
        tracing::info!(target: "idfon.holder", subject = %subject, path = %path, "admitted voice-delegate caller");
    }
}

fn voice_route_from_live_params(params: &serde_json::Value) -> VoiceRoute {
    if let Some(voice) = params.get("voice_route") {
        if let Ok(route) = serde_json::from_value::<VoiceRoute>(voice.clone()) {
            return route;
        }
    }
    if params.is_null() {
        return VoiceRoute::default();
    }
    VoiceRoute {
        mode: VoiceMode::NativeDuplex,
        // Holder-declared codec; default to the live PCM profile when the
        // config doesn't name one, so the caller never has to guess.
        audio: params
            .get("audio")
            .and_then(|value| value.as_str())
            .map(str::to_owned)
            .or_else(|| Some("pcm24k".to_owned())),
        model: params.get("model").and_then(|value| value.as_str()).map(str::to_owned),
        delegate: None,
        stt: None,
        tts: None,
    }
}

fn load_ticket(path: &Path) -> Result<CapabilityTicket> {
    serde_json::from_slice(
        &std::fs::read(path).with_context(|| format!("read ticket {}", path.display()))?,
    )
    .with_context(|| format!("parse ticket {}", path.display()))
}

fn load_key(path: Option<&Path>, ephemeral: bool) -> Result<SigningKey> {
    let value = match path {
        Some(path) => Some(
            std::fs::read_to_string(path)
                .with_context(|| format!("read key file {}", path.display()))?,
        ),
        None => std::env::var("EVE_IDFON_KEY").ok(),
    };
    match value.filter(|value| !value.trim().is_empty()) {
        Some(value) => idfon_core::decode_signing_key(value.trim())
            .ok_or_else(|| anyhow!("invalid key: expected 64 hex characters")),
        None if ephemeral => {
            tracing::warn!(target: "idfon.holder", "no stable key; using an ephemeral identity");
            Ok(idfon_core::generate_identity())
        }
        None => Err(anyhow!(
            "no key configured; pass --key-file, EVE_IDFON_KEY, or --ephemeral"
        )),
    }
}

async fn serve(
    socket: PathBuf,
    allow: Vec<String>,
    allow_file: Option<PathBuf>,
    key: SigningKey,
    blob_dir: PathBuf,
    reply_ticket: Option<CapabilityTicket>,
    live_ttl_secs: u64,
    live_registry: Arc<live::LiveCallRegistry>,
    live_params: serde_json::Value,
) -> Result<()> {
    if socket.exists() {
        std::fs::remove_file(&socket)
            .with_context(|| format!("remove stale socket {}", socket.display()))?;
    }
    if let Some(parent) = socket.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create socket directory {}", parent.display()))?;
    }
    let listener = UnixListener::bind(&socket)
        .with_context(|| format!("bind Unix socket {}", socket.display()))?;
    let transport = Arc::new(
        IrohTransport::bind_with_key(Some(idfon_core::signing_key_bytes(&key)))
            .await
            .context("bind iroh endpoint")?,
    );
    let blob_store = FsStore::load(&blob_dir).await.context("load blob store")?;
    let blob_endpoint = Endpoint::bind(presets::N0)
        .await
        .context("bind blob endpoint")?;
    let blob_router = Router::builder(blob_endpoint.clone())
        .accept(BLOBS_ALPN, BlobsProtocol::new(blob_store.as_ref(), None))
        .spawn();
    let _ = tokio::time::timeout(std::time::Duration::from_secs(5), blob_endpoint.online()).await;
    let _ = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        transport.endpoint().online(),
    )
    .await;
    println!(
        "{}",
        serde_json::to_string(&transport.endpoint().addr()).context("serialize endpoint ticket")?
    );
    tracing::info!(
        target: "idfon.holder",
        identity = %transport.endpoint().id(),
        "serving"
    );

    let (stream, _) = listener.accept().await.context("accept IPC client")?;
    let (reader, writer) = stream.into_split();
    let (out_tx, out_rx) = mpsc::channel(64);
    tokio::spawn(write_frames(writer, out_rx));
    let (reply_tx, mut reply_rx) = mpsc::channel(64);
    tokio::spawn(read_frames(reader, reply_tx));

    let targets = Targets::default();
    let seen = Seen::default();
    let rate_limits = RateLimits::default();
    let live_publishers: LivePublishers = Arc::new(Mutex::new(HashMap::new()));
    let live_cleanup = {
        let live_publishers = Arc::clone(&live_publishers);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(60));
            loop {
                interval.tick().await;
                cleanup_live_publishers(&live_publishers).await;
            }
        })
    };
    let holder_peer_id = peer_id(&key);
    // Advertised on every ticket this holder mints and used to decide whether
    // inbound live controls should reach a registered live-call handler.
    let voice_route = voice_route_from_live_params(&live_params);
    let delegate_allow_file = live_params
        .get("voice_delegate_allow_file")
        .and_then(|value| value.as_str())
        .map(str::to_owned);
    // Senders admitted dynamically while running (e.g. an agency provisioner
    // inviting a caller) are unioned with the static --allow list from the
    // allow-file, which the holder reloads while running.
    let static_allow = allow;
    let mut initial = static_allow.clone();
    if let Some(path) = &allow_file {
        initial.extend(load_allow_file(path));
    }
    initial.sort();
    initial.dedup();
    let allow: Arc<RwLock<Vec<String>>> = Arc::new(RwLock::new(initial));
    if let Some(path) = allow_file.clone() {
        let allow = Arc::clone(&allow);
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_millis(500));
            loop {
                interval.tick().await;
                let next = merge_allow(&static_allow, &load_allow_file(&path));
                let mut guard = allow.write().await;
                if *guard != next {
                    *guard = next;
                }
            }
        });
    }
    let transport_task = {
        let transport = Arc::clone(&transport);
        let targets = Arc::clone(&targets);
        let seen = Arc::clone(&seen);
        let rate_limits = Arc::clone(&rate_limits);
        let out_tx = out_tx.clone();
        let allow = Arc::clone(&allow);
        let holder_peer_id = holder_peer_id.clone();
        let transport_for_calls = Arc::clone(&transport);
        let key_for_calls = key.clone();
        let live_registry = Arc::clone(&live_registry);
        let live_params = live_params.clone();
        tokio::spawn(async move {
            transport
                .serve_with_peer(move |message, remote_id| {
                    // One span per admitted crossing: the OTel trace root for
                    // this process, continuing the sender's trace when present.
                    let span = tracing::info_span!(
                        "idfon.seam",
                        direction = "in",
                        kind = "message",
                        message_id = %message.message_id,
                        peer_id = %message.sender.peer_id,
                        trace = ?message.trace,
                        telemetry = ?message.telemetry,
                    );
                    idfon_telemetry::set_remote_parent(&span, message.trace.as_deref());
                    handle_message(
                        message,
                        remote_id.to_string(),
                        Arc::clone(&targets),
                        Arc::clone(&seen),
                        Arc::clone(&rate_limits),
                        out_tx.clone(),
                        allow.clone(),
                        holder_peer_id.clone(),
                        Arc::clone(&transport_for_calls),
                        key_for_calls.clone(),
                        Arc::clone(&live_registry),
                        live_params.clone(),
                    )
                    .instrument(span)
                })
                .await
        })
    };

    while let Some(frame) = reply_rx.recv().await {
        let result = match frame {
            IpcFrame::ReplyOut { .. } => {
                handle_reply(
                    frame,
                    &key,
                    &transport,
                    &targets,
                    reply_ticket.as_ref(),
                    out_tx.clone(),
                )
                .await
            }
            IpcFrame::StatusOut {
                request_id,
                in_reply_to,
                event,
                data,
            } => {
                handle_status(
                    request_id,
                    in_reply_to,
                    event,
                    data,
                    &key,
                    &transport,
                    &targets,
                    reply_ticket.as_ref(),
                    out_tx.clone(),
                )
                .await
            }
            IpcFrame::BlobFetch { request_id, ticket } => {
                handle_blob_fetch(request_id, ticket, &blob_dir, &blob_store, out_tx.clone()).await
            }
            IpcFrame::BlobPut {
                request_id,
                bytes_base64,
            } => {
                handle_blob_put(
                    request_id,
                    bytes_base64,
                    &blob_store,
                    &blob_endpoint,
                    out_tx.clone(),
                )
                .await
            }
            IpcFrame::RecordsDrain {
                request_id,
                peer_id,
                turn_id,
            } => {
                let records = records::store()
                    .drain(&peer_id, &turn_id)
                    .into_iter()
                    .filter_map(|record| serde_json::to_value(record).ok())
                    .collect();
                out_tx
                    .send(IpcFrame::RecordsDrainResult {
                        request_id,
                        records,
                    })
                    .await
                    .map_err(|_| anyhow!("IPC client disconnected"))
            }
            IpcFrame::StreamAppend {
                request_id,
                peer_id,
                turn_id,
                step_index,
                sequence,
                text,
            } => {
                // F11: deliver agent-output deltas to the active voice call's
                // TTS (clause batching + retry dedupe live in `idfon-voice`
                // `StreamingSpeaker`). No subscriber => accept and log, as
                // before, so the transport stays exercised for text turns.
                let accepted = !text.is_empty();
                if accepted {
                    let routed = peer_id
                        .as_deref()
                        .map(|peer| {
                            deltas::route(
                                peer,
                                (turn_id.clone(), step_index, sequence, text.clone()),
                            )
                        })
                        .unwrap_or(false);
                    if !routed {
                        tracing::info!(
                            target: "idfon.holder",
                            turn_id = %turn_id,
                            step = step_index,
                            seq = sequence,
                            chars = text.chars().count(),
                            "stream delta not routed"
                        );
                    }
                }
                out_tx
                    .send(IpcFrame::StreamAppendResult {
                        request_id,
                        accepted,
                    })
                    .await
                    .map_err(|_| anyhow!("IPC client disconnected"))
            }
            IpcFrame::AudioAppend {
                request_id,
                peer_id,
                pcm_base64,
            } => {
                let accepted = BASE64
                    .decode(&pcm_base64)
                    .ok()
                    .map(|bytes| {
                        let samples: Vec<i16> = bytes
                            .chunks_exact(2)
                            .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                            .collect();
                        live_audio::append(&peer_id, samples)
                    })
                    .unwrap_or(false);
                out_tx
                    .send(IpcFrame::AudioAppendResult {
                        request_id,
                        accepted,
                    })
                    .await
                    .map_err(|_| anyhow!("IPC client disconnected"))
            }
            IpcFrame::LivePublish {
                request_id,
                path,
                loop_playback,
                name,
                relay,
                video,
                quality,
            } => {
                handle_live_publish(
                    request_id,
                    path,
                    loop_playback,
                    name,
                    relay,
                    video,
                    quality,
                    live_ttl_secs,
                    &live_publishers,
                    out_tx.clone(),
                )
                .await
            }
            IpcFrame::LiveStop { request_id, id } => {
                handle_live_stop(request_id, id, &live_publishers, out_tx.clone()).await
            }
            IpcFrame::TicketIssue {
                request_id,
                subject,
                capabilities,
            } => {
                handle_ticket_issue(
                    request_id,
                    subject,
                    capabilities,
                    &key,
                    &transport,
                    &voice_route,
                    delegate_allow_file.as_deref(),
                    out_tx.clone(),
                )
                .await
            }
            IpcFrame::InputOut {
                request_id,
                peer_id,
                endpoint_id,
                conversation,
                requests,
            } => {
                handle_input(
                    request_id,
                    peer_id,
                    endpoint_id,
                    conversation,
                    requests,
                    &key,
                    &transport,
                    out_tx.clone(),
                )
                .await
            }
            IpcFrame::PeerSendOut {
                request_id,
                peer_id,
                endpoint_id,
                conversation,
                text,
                capability_ticket,
                a2a_depth,
            } => {
                handle_peer_send(
                    request_id,
                    peer_id,
                    endpoint_id,
                    conversation,
                    text,
                    capability_ticket,
                    a2a_depth,
                    &key,
                    &transport,
                    out_tx.clone(),
                )
                .await
            }
            _ => Err(anyhow!("unexpected IPC frame from consumer")),
        };
        if let Err(error) = result {
            let _ = out_tx
                .send(IpcFrame::Error {
                    code: "ipc_request_failed".into(),
                    message: error.to_string(),
                })
                .await;
        }
    }

    transport_task.abort();
    let _ = transport_task.await;
    live_cleanup.abort();
    let _ = live_cleanup.await;
    stop_all_live_publishers(&live_publishers).await;
    let _ = blob_router.shutdown().await;
    blob_endpoint.close().await;
    let _ = std::fs::remove_file(&socket);
    // Flush buffered OTLP spans on a clean shutdown (no-op without the exporter).
    idfon_telemetry::shutdown();
    Ok(())
}

/// Static allow entries unioned with the allow-file's, sorted and deduped.
fn merge_allow(static_allow: &[String], file_allow: &[String]) -> Vec<String> {
    let mut merged = static_allow.to_vec();
    merged.extend_from_slice(file_allow);
    merged.sort();
    merged.dedup();
    merged
}

/// Trimmed, non-empty, sorted, deduped sender ids from an allow-file. A
/// missing file is empty (deny-all additions).
fn load_allow_file(path: &Path) -> Vec<String> {
    let Ok(contents) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut peers: Vec<String> = contents
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect();
    peers.sort();
    peers.dedup();
    peers
}

async fn handle_message(
    message: MessageEnvelope,
    remote_endpoint_id: String,
    targets: Targets,
    seen: Seen,
    rate_limits: RateLimits,
    out_tx: mpsc::Sender<IpcFrame>,
    allow: Arc<RwLock<Vec<String>>>,
    holder_peer_id: String,
    transport_for_calls: Arc<IrohTransport>,
    key_for_calls: SigningKey,
    live_registry: Arc<live::LiveCallRegistry>,
    live_params: serde_json::Value,
) -> std::result::Result<MessageAck, TransportError> {
    let ticket = {
        let allow = allow.read().await;
        match validate_message(&message, &remote_endpoint_id, allow.as_slice(), &holder_peer_id) {
            Ok(ticket) => ticket,
            Err(error) => {
                tracing::warn!(
                    target: "idfon.holder",
                    message_id = %message.message_id,
                    sender = %message.sender.peer_id,
                    signed_endpoint = %message.sender.endpoint_id,
                    remote_endpoint = %remote_endpoint_id,
                    ticket_issuer = ?message.capability_ticket.as_ref().map(|ticket| ticket.issuer.as_str()),
                    ticket_subject = ?message.capability_ticket.as_ref().and_then(|ticket| ticket.subject.as_deref()),
                    error = %error,
                    "rejected message"
                );
                let _ = out_tx
                    .send(IpcFrame::Error {
                        code: error.code().into(),
                        message: error.to_string(),
                    })
                    .await;
                return Err(TransportError::Failed(error.to_string()));
            }
        }
    };
    let wire_text = match &message.content {
        MessageContent::Text { text } => text.clone(),
    };
    let (text, a2a_depth) = parse_a2a_envelope(&wire_text)
        .map(|envelope| (envelope.text, Some(envelope.depth)))
        .unwrap_or((wire_text.clone(), None));
    if a2a_depth.is_some()
        && !ticket
            .capabilities
            .contains(&Capability::new("agent.receive"))
    {
        let error = HolderError::AgentCapabilityDenied;
        let _ = out_tx
            .send(IpcFrame::Error {
                code: error.code().into(),
                message: error.to_string(),
            })
            .await;
        return Err(TransportError::Failed(error.to_string()));
    }
    if !admit_message(&rate_limits, &message.sender.peer_id).await {
        let error = HolderError::RateLimited;
        let _ = out_tx
            .send(IpcFrame::Error {
                code: error.code().into(),
                message: error.to_string(),
            })
            .await;
        return Err(TransportError::Failed(error.to_string()));
    }
    let attachment = parse_data_envelope(&text);
    // Voice is 1:1 only: track room membership by distinct senders so a
    // conversation-addressed call can be rejected without assuming that any
    // set `conversation` is a room (a threaded 1:1 sets one too).
    if let Some(conversation) = &message.conversation {
        rooms::registry().observe(conversation, &message.sender.peer_id);
    }
    let key = (
        message.sender.peer_id.clone(),
        message.idempotency_key.clone(),
    );
    {
        let mut seen_guard = seen.lock().await;
        if let Some(existing) = seen_guard.get(&key) {
            if existing != &wire_text {
                let error = HolderError::IdempotencyConflict;
                let _ = out_tx
                    .send(IpcFrame::Error {
                        code: error.code().into(),
                        message: error.to_string(),
                    })
                    .await;
                return Err(TransportError::Failed(error.to_string()));
            }
            if text.starts_with("IDFON-LIVE/1") {
                tracing::info!(
                    target: "idfon.holder",
                    peer_id = %message.sender.peer_id,
                    idempotency_key = %message.idempotency_key,
                    "duplicate live control ignored"
                );
            }
            return Ok(MessageAck {
                message_id: message.message_id,
                status: AckStatus::Duplicate,
            });
        }
        if seen_guard.len() >= MAX_SEEN_MESSAGES {
            let error = HolderError::ResourceLimit;
            let _ = out_tx
                .send(IpcFrame::Error {
                    code: error.code().into(),
                    message: error.to_string(),
                })
                .await;
            return Err(TransportError::Failed(error.to_string()));
        }
        seen_guard.insert(key, wire_text);
    }

    // Canonical boundary event: one structured line per admitted crossing, so
    // triage can join daemon/agent/holder logs on message_id / peer_id.
    tracing::info!(
        target: "idfon.seam",
        direction = "in",
        kind = "message",
        message_id = %message.message_id,
        peer_id = %message.sender.peer_id,
        endpoint_id = %remote_endpoint_id,
        conversation = message.conversation.as_deref().unwrap_or(""),
        a2a_depth = a2a_depth.unwrap_or(0),
        attachment = attachment.is_some(),
        trace = ?message.trace,
        telemetry = ?message.telemetry,
        "boundary"
    );

    // Deduplicate call controls before they mutate the active session; transport
    // retries must not replace a call that is already running. Voice is 1:1
    // only; room membership is recorded per inbound message (below) and the
    // room check lives in the registered live-call handler, which falls through
    // to a text turn for a room.
    if let Some(capability) = live::capability_for_control(&text) {
        // Only a holder that terminates audio itself (native full-duplex or the
        // server-side cascade) may intercept a call; a text-only holder
        // (voice.mode = client-cascade) falls through to an ordinary text turn
        // so the caller's on-device STT/TTS drives it.
        let voice_mode = voice_route_from_live_params(&live_params).mode;
        if !matches!(
            voice_mode,
            VoiceMode::NativeDuplex | VoiceMode::ServerCascade
        ) {
            tracing::info!(
                target: "idfon.holder",
                voice_mode = ?voice_mode,
                message_id = %message.message_id,
                "live control ignored (text turn)"
            );
        } else if let Some(handler) = live_registry.get(capability).cloned() {
            tracing::info!(
                target: "idfon.holder",
                capability = %capability,
                message_id = %message.message_id,
                idempotency_key = %message.idempotency_key,
                "dispatch live control"
            );
            let ctx = live::LiveCallContext {
                text: text.clone(),
                sender_peer_id: message.sender.peer_id.clone(),
                sender_endpoint_id: message.sender.endpoint_id.clone(),
                conversation: message.conversation.clone(),
                holder_endpoint_id: holder_peer_id.clone(),
                transport: Arc::clone(&transport_for_calls),
                key: key_for_calls.clone(),
                targets: Arc::clone(&targets),
                out_tx: out_tx.clone(),
                params: live_params.clone(),
            };
            match handler.handle(ctx).await {
                Ok(true) => {
                    return Ok(MessageAck {
                        message_id: message.message_id,
                        status: AckStatus::Accepted,
                    });
                }
                Ok(false) => {}
                Err(error) => {
                    return Err(TransportError::Failed(format!(
                        "live call failed: {error:#}"
                    )));
                }
            }
        }
    }

    if let Some((event, data)) = parse_status_envelope(&text) {
        out_tx
            .send(IpcFrame::StatusIn {
                message_id: message.message_id.clone(),
                peer_id: message.sender.peer_id.clone(),
                endpoint_id: remote_endpoint_id,
                conversation: message.conversation.clone(),
                event,
                data,
            })
            .await
            .map_err(|_| TransportError::Failed("IPC client disconnected".into()))?;
        return Ok(MessageAck {
            message_id: message.message_id,
            status: AckStatus::Accepted,
        });
    }

    if let Some(responses) = parse_input_response(&text) {
        out_tx
            .send(IpcFrame::InputIn {
                message_id: message.message_id.clone(),
                peer_id: message.sender.peer_id.clone(),
                endpoint_id: remote_endpoint_id,
                conversation: message.conversation.clone(),
                responses,
                capabilities: Some(
                    ticket
                        .capabilities
                        .iter()
                        .map(|capability| capability.0.to_string())
                        .collect(),
                ),
            })
            .await
            .map_err(|_| TransportError::Failed("IPC client disconnected".into()))?;
        return Ok(MessageAck {
            message_id: message.message_id,
            status: AckStatus::Accepted,
        });
    }

    // Message ids are daemon-local, so two peers can legitimately both send
    // `msg_1`. The reply route must be globally unique within this holder.
    let reply_key = format!("{}:{}", message.sender.peer_id, message.message_id);
    let mut targets_guard = targets.lock().await;
    if targets_guard.len() >= MAX_TARGETS {
        let error = HolderError::ResourceLimit;
        let _ = out_tx
            .send(IpcFrame::Error {
                code: error.code().into(),
                message: error.to_string(),
            })
            .await;
        return Err(TransportError::Failed(error.to_string()));
    }
    targets_guard.insert(
        reply_key.clone(),
        ReplyTarget {
            peer_id: message.sender.peer_id.clone(),
            endpoint_id: remote_endpoint_id.clone(),
            conversation: message.conversation.clone(),
            a2a_depth,
            live_commentary: None,
            live_only: false,
            trace: message.trace.clone(),
        },
    );
    drop(targets_guard);
    out_tx
        .send(IpcFrame::TurnIn {
            message_id: reply_key,
            peer_id: message.sender.peer_id.clone(),
            endpoint_id: remote_endpoint_id,
            idempotency_key: message.idempotency_key.clone(),
            conversation: message.conversation.clone(),
            // Keep the original envelope text when the attachment type has no
            // byte size (e.g. recordings carry duration_ms instead) so the
            // agent sees the full metadata rather than "0 bytes".
            text: match &attachment {
                Some((_, Some(size))) => format!("Attached file ({} bytes)", size),
                _ => text,
            },
            blob_ticket: attachment.as_ref().map(|(ticket, _)| ticket.clone()),
            size_bytes: attachment.as_ref().and_then(|(_, size)| *size),
            a2a_depth,
            capabilities: Some(
                ticket
                    .capabilities
                    .iter()
                    .map(|capability| capability.0.to_string())
                    .collect(),
            ),
            source: None,
        })
        .await
        .map_err(|_| TransportError::Failed("IPC client disconnected".into()))?;
    Ok(MessageAck {
        message_id: message.message_id,
        status: AckStatus::Accepted,
    })
}

async fn admit_message(rate_limits: &RateLimits, peer_id: &str) -> bool {
    let now = Instant::now();
    let window = Duration::from_secs(60);
    let mut limits = rate_limits.lock().await;
    let entries = limits.entry(peer_id.to_owned()).or_default();
    while entries
        .front()
        .is_some_and(|started| now.duration_since(*started) >= window)
    {
        entries.pop_front();
    }
    if entries.len() >= MAX_MESSAGES_PER_PEER_PER_MINUTE {
        return false;
    }
    entries.push_back(now);
    true
}

async fn handle_reply(
    frame: IpcFrame,
    key: &SigningKey,
    transport: &IrohTransport,
    targets: &Targets,
    reply_ticket: Option<&CapabilityTicket>,
    out_tx: mpsc::Sender<IpcFrame>,
) -> Result<()> {
    let IpcFrame::ReplyOut {
        in_reply_to,
        text,
        idempotency_key,
    } = frame
    else {
        return Err(anyhow!("expected reply.out frame"));
    };
    let target_key = in_reply_to
        .split_once('|')
        .map_or(in_reply_to.as_str(), |(key, _)| key);
    let target = targets
        .lock()
        .await
        .get(target_key)
        .cloned()
        .ok_or_else(|| anyhow!("unknown in_reply_to {}", in_reply_to))?;
    // A live-call delegation also wants the spoken text (envelopes stripped)
    // fed back to the live session; capture it before `text` moves.
    let commentary = target.live_commentary.clone();
    let commentary_text = commentary.as_ref().map(|_| strip_envelopes(&text));
    let message_id = next_message_id("eve_reply_");
    // A voice-injected turn is spoken to the live session only (no chat copy);
    // a normal turn also posts to the caller. Either way the bridge is awaiting
    // a `reply.ack` keyed by `in_reply_to` — without it `/reply` returns 502 and
    // the agent's reply is dropped before it reaches the live session.
    let status = if target.live_only {
        "delivered".to_string()
    } else {
        let endpoint_id: EndpointId = target
            .endpoint_id
            .parse()
            .map_err(|error| anyhow!("invalid target endpoint ID: {error}"))?;
        let target_addr = EndpointAddr::new(endpoint_id);
        let text = target
            .a2a_depth
            .map(|depth| encode_a2a_envelope(depth.saturating_add(1), &text, target.trace.as_deref(), Some(idfon_telemetry::mode())))
            .unwrap_or(text);
        let reply_ticket = reply_ticket
            .filter(|ticket| ticket.issuer == target.peer_id)
            .cloned();
        let mut envelope = sign_message_with_ticket(
            key,
            peer_id(key),
            message_id.clone(),
            MessageContent::Text { text },
            idempotency_key.unwrap_or_else(|| format!("eve-reply-{in_reply_to}")),
            target.conversation,
            reply_ticket,
        )
        .map_err(|error| anyhow!("sign reply: {error}"))?;
        envelope.trace = target.trace.clone();
        envelope.telemetry = Some(idfon_telemetry::mode().to_string());
        match transport.send(&target_addr, &envelope).await {
            Ok(ack) => format!("{:?}", ack.status).to_lowercase(),
            Err(error) => {
                tracing::warn!(target: "idfon.holder", peer_id = %target.peer_id, error = %error, "send reply failed");
                "failed".to_string()
            }
        }
    };
    tracing::info!(
        target: "idfon.seam",
        direction = "out",
        kind = "reply",
        in_reply_to = %in_reply_to,
        message_id = %message_id,
        peer_id = %target.peer_id,
        live_only = target.live_only,
        status = %status,
        trace = ?target.trace,
        "boundary"
    );
    out_tx
        .send(IpcFrame::ReplyAck {
            in_reply_to,
            message_id,
            status,
        })
        .await
        .map_err(|_| anyhow!("IPC client disconnected"))?;
    if let (Some((delegation_id, sender)), Some(spoken)) = (commentary, commentary_text) {
        if !spoken.is_empty() {
            let _ = sender.send((delegation_id, spoken));
        }
    }
    Ok(())
}

/// Drop trailing `IDFON-*/1` envelope blocks, keeping only the spoken text a
/// voice session should say. Envelope headers are the first line of a block.
fn strip_envelopes(text: &str) -> String {
    let mut cut = text.len();
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.starts_with("IDFON-") && trimmed.ends_with("/1") {
            cut = offset;
            break;
        }
        offset += line.len();
    }
    text[..cut].trim_end().to_string()
}

async fn handle_status(
    request_id: String,
    in_reply_to: String,
    event: String,
    data: serde_json::Value,
    key: &SigningKey,
    transport: &IrohTransport,
    targets: &Targets,
    reply_ticket: Option<&CapabilityTicket>,
    out_tx: mpsc::Sender<IpcFrame>,
) -> Result<()> {
    let target = targets
        .lock()
        .await
        .get(&in_reply_to)
        .cloned()
        .ok_or_else(|| anyhow!("unknown in_reply_to {in_reply_to}"))?;
    let endpoint_id: EndpointId = target
        .endpoint_id
        .parse()
        .map_err(|error| anyhow!("invalid target endpoint ID: {error}"))?;
    let message_id = next_message_id("eve_status_");
    let reply_ticket = reply_ticket
        .filter(|ticket| ticket.issuer == target.peer_id)
        .cloned();
    let mut envelope = sign_message_with_ticket(
        key,
        peer_id(key),
        message_id.clone(),
        MessageContent::Text {
            text: encode_status_envelope(&event, &data)?,
        },
        format!("eve-status-{message_id}"),
        target.conversation,
        reply_ticket,
    )
    .map_err(|error| anyhow!("sign status: {error}"))?;
    envelope.trace = target.trace.clone();
    envelope.telemetry = Some(idfon_telemetry::mode().to_string());
    transport
        .send(&EndpointAddr::new(endpoint_id), &envelope)
        .await
        .map_err(|error| anyhow!("send status to {}: {error}", target.peer_id))?;
    tracing::info!(
        target: "idfon.seam",
        direction = "out",
        kind = "status",
        in_reply_to = %in_reply_to,
        message_id = %message_id,
        peer_id = %target.peer_id,
        event = %event,
        trace = ?envelope.trace,
        "boundary"
    );
    targets.lock().await.remove(&in_reply_to);
    out_tx
        .send(IpcFrame::StatusAck {
            request_id,
            in_reply_to,
            message_id,
            event,
        })
        .await
        .map_err(|_| anyhow!("IPC client disconnected"))?;
    Ok(())
}

async fn handle_input(
    request_id: String,
    target_peer_id: String,
    endpoint_id: String,
    conversation: Option<String>,
    requests: serde_json::Value,
    key: &SigningKey,
    transport: &IrohTransport,
    out_tx: mpsc::Sender<IpcFrame>,
) -> Result<()> {
    let endpoint_id: EndpointId = endpoint_id
        .parse()
        .map_err(|error| anyhow!("invalid target endpoint ID: {error}"))?;
    let payload = serde_json::to_vec(&requests).context("encode input requests")?;
    let text = format!("IDFON-HITL/1\npayload={}\n", BASE64.encode(payload));
    let message_id = next_message_id("eve_input_");
    let mut envelope = sign_message(
        key,
        peer_id(key),
        message_id.clone(),
        MessageContent::Text { text },
        format!("eve-input-{request_id}"),
        conversation,
    )
    .map_err(|error| anyhow!("sign input request: {error}"))?;
    envelope.trace = Some(idfon_core::new_traceparent());
    envelope.telemetry = Some(idfon_telemetry::mode().to_string());
    let ack = transport
        .send(&EndpointAddr::new(endpoint_id), &envelope)
        .await
        .map_err(|error| anyhow!("send input request to {target_peer_id}: {error}"))?;
    tracing::info!(
        target: "idfon.seam",
        direction = "out",
        kind = "input",
        request_id = %request_id,
        message_id = %message_id,
        peer_id = %target_peer_id,
        status = ?ack.status,
        trace = ?envelope.trace,
        "boundary"
    );
    out_tx
        .send(IpcFrame::InputAck {
            request_id,
            message_id,
            status: format!("{:?}", ack.status).to_lowercase(),
        })
        .await
        .map_err(|_| anyhow!("IPC client disconnected"))?;
    Ok(())
}

fn encode_a2a_envelope(
    depth: u8,
    text: &str,
    trace: Option<&str>,
    telemetry: Option<&str>,
) -> String {
    let mut envelope = format!("IDFON-A2A/1\ndepth={depth}\n");
    // Offered to the agent as optional correlation/participation hints; older
    // decoders ignore unknown lines.
    if let Some(trace) = trace {
        envelope.push_str(&format!("trace={trace}\n"));
    }
    if let Some(telemetry) = telemetry {
        envelope.push_str(&format!("telemetry={telemetry}\n"));
    }
    envelope.push_str(&format!("payload={}\n", BASE64.encode(text.as_bytes())));
    envelope
}

#[derive(Debug, PartialEq)]
struct A2aEnvelope {
    depth: u8,
    text: String,
    trace: Option<String>,
    telemetry: Option<String>,
}

fn parse_a2a_envelope(text: &str) -> Option<A2aEnvelope> {
    let mut depth = None;
    let mut payload = None;
    let mut trace = None;
    let mut telemetry = None;
    for line in text.strip_prefix("IDFON-A2A/1\n")?.lines() {
        let (key, value) = line.split_once('=')?;
        match key {
            "depth" => depth = value.parse().ok(),
            "trace" => trace = Some(value.to_owned()),
            "telemetry" => telemetry = Some(value.to_owned()),
            "payload" => payload = Some(value),
            _ => {}
        }
    }
    Some(A2aEnvelope {
        depth: depth?,
        text: String::from_utf8(BASE64.decode(payload?).ok()?).ok()?,
        trace,
        telemetry,
    })
}

fn encode_status_envelope(event: &str, data: &serde_json::Value) -> Result<String> {
    let payload = serde_json::json!({ "event": event, "data": data });
    Ok(format!(
        "IDFON-STATUS/1\npayload={}\n",
        BASE64.encode(serde_json::to_vec(&payload)?)
    ))
}

fn parse_status_envelope(text: &str) -> Option<(String, serde_json::Value)> {
    let encoded = text
        .strip_prefix("IDFON-STATUS/1\n")?
        .lines()
        .find_map(|line| line.strip_prefix("payload="))?;
    let payload = BASE64.decode(encoded).ok()?;
    let value: serde_json::Value = serde_json::from_slice(&payload).ok()?;
    Some((
        value.get("event")?.as_str()?.to_owned(),
        value.get("data")?.clone(),
    ))
}

fn parse_input_response(text: &str) -> Option<serde_json::Value> {
    let encoded = text
        .strip_prefix("IDFON-HITL-RESPONSE/1\n")?
        .lines()
        .find_map(|line| line.strip_prefix("payload="))?;
    let payload = BASE64.decode(encoded).ok()?;
    serde_json::from_slice(&payload).ok()
}

async fn handle_peer_send(
    request_id: String,
    target_peer_id: String,
    endpoint_id: String,
    conversation: Option<String>,
    text: String,
    capability_ticket: serde_json::Value,
    a2a_depth: u8,
    key: &SigningKey,
    transport: &IrohTransport,
    out_tx: mpsc::Sender<IpcFrame>,
) -> Result<()> {
    let endpoint_id: EndpointId = endpoint_id
        .parse()
        .map_err(|error| anyhow!("invalid target endpoint ID: {error}"))?;
    let ticket = if capability_ticket.is_null() {
        None
    } else {
        Some(
            serde_json::from_value(capability_ticket)
                .context("decode outbound capability ticket")?,
        )
    };
    let message_id = next_message_id("eve_peer_");
    let trace = idfon_core::new_traceparent();
    let text = encode_a2a_envelope(a2a_depth, &text, Some(&trace), Some(idfon_telemetry::mode()));
    let mut envelope = sign_message_with_ticket(
        key,
        peer_id(key),
        message_id.clone(),
        MessageContent::Text { text },
        format!("eve-peer-{request_id}"),
        conversation,
        ticket,
    )
    .map_err(|error| anyhow!("sign peer message: {error}"))?;
    envelope.trace = Some(trace);
    envelope.telemetry = Some(idfon_telemetry::mode().to_string());
    let ack = transport
        .send(&EndpointAddr::new(endpoint_id), &envelope)
        .await
        .map_err(|error| anyhow!("send peer message to {target_peer_id}: {error}"))?;
    tracing::info!(
        target: "idfon.seam",
        direction = "out",
        kind = "peer_send",
        request_id = %request_id,
        message_id = %message_id,
        peer_id = %target_peer_id,
        status = ?ack.status,
        trace = ?envelope.trace,
        "boundary"
    );
    out_tx
        .send(IpcFrame::PeerSendAck {
            request_id,
            message_id,
            status: format!("{:?}", ack.status).to_lowercase(),
        })
        .await
        .map_err(|_| anyhow!("IPC client disconnected"))?;
    Ok(())
}

fn parse_data_envelope(text: &str) -> Option<(String, Option<u64>)> {
    // Both attachment envelope types carry `ticket=`; recordings also carry
    // `duration_ms` etc. Size is only present on IDFON-DATA/1.
    let mut ticket = None;
    let mut size = None;
    let body = text
        .strip_prefix("IDFON-DATA/1\n")
        .or_else(|| text.strip_prefix("IDFON-RECORDING/1\n"))?;
    // A turn can carry a trailing reference/artifact envelope after the
    // attachment (a voice memo asking about an artifact region). Only parse
    // the attachment's own lines, and skip any line that is not `key=value`.
    let body = body.split("\nIDFON-").next().unwrap_or(body);
    for line in body.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "ticket" => ticket = Some(value.to_owned()),
            "size" => size = value.parse().ok(),
            _ => {}
        }
    }
    Some((ticket?, size))
}

async fn handle_blob_fetch(
    request_id: String,
    ticket: String,
    root: &Path,
    store: &FsStore,
    out_tx: mpsc::Sender<IpcFrame>,
) -> Result<()> {
    let ticket: BlobTicket = ticket.parse().context("parse blob ticket")?;
    tokio::fs::create_dir_all(root).await?;
    // The sender's first pkarr publish may still be propagating. Fresh
    // endpoints avoid reusing a resolver poisoned by a negative lookup.
    // ponytail: 6 attempts x 1s; await publish completion if this grows flaky.
    let mut last_error = None;
    let mut bytes = None;
    for attempt in 0..6 {
        if attempt > 0 {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
        let endpoint = Endpoint::bind(presets::N0).await?;
        let result = fetch_blob_once(&ticket, &endpoint, store, root).await;
        endpoint.close().await;
        match result {
            Ok(value) => {
                bytes = Some(value);
                break;
            }
            Err(error) => last_error = Some(error),
        }
    }
    let bytes = bytes.ok_or_else(|| last_error.expect("at least one blob fetch attempt"))?;
    out_tx
        .send(IpcFrame::BlobResult {
            request_id,
            size_bytes: bytes.len() as u64,
            bytes_base64: BASE64.encode(bytes),
        })
        .await
        .map_err(|_| anyhow!("IPC client disconnected"))?;
    Ok(())
}

async fn fetch_blob_once(
    ticket: &BlobTicket,
    endpoint: &Endpoint,
    store: &FsStore,
    root: &Path,
) -> Result<Vec<u8>> {
    tokio::time::timeout(
        std::time::Duration::from_secs(30),
        store
            .downloader(endpoint)
            .download(ticket.hash(), Some(ticket.addr().id)),
    )
    .await??;
    let output = root.join(format!("{}.blob", ticket.hash()));
    store.blobs().export(ticket.hash(), &output).await?;
    Ok(tokio::fs::read(output).await?)
}

async fn handle_live_publish(
    request_id: String,
    path: String,
    loop_playback: bool,
    name: String,
    relay: bool,
    video: bool,
    quality: Option<String>,
    live_ttl_secs: u64,
    publishers: &LivePublishers,
    out_tx: mpsc::Sender<IpcFrame>,
) -> Result<()> {
    cleanup_live_publishers(publishers).await;
    if publishers.lock().await.len() >= MAX_LIVE_PUBLISHERS {
        return Err(anyhow!("live publisher limit exceeded"));
    }
    let path = PathBuf::from(path);
    let (publisher, ticket) = if video {
        let presets = video_presets(quality.as_deref())?;
        let (publisher, ticket) =
            idfon_media::video::VideoPublisher::start(&path, &name, relay, presets)
                .with_context(|| format!("publish live video from {}", path.display()))?;
        (LivePublisherKind::Video(publisher), ticket)
    } else {
        let (publisher, ticket) =
            idfon_media::live::LivePublisher::start(&path, loop_playback, &name, relay)
                .with_context(|| format!("publish live audio from {}", path.display()))?;
        (LivePublisherKind::Audio(publisher), ticket)
    };
    let id = format!("live-{}", NEXT_REPLY_ID.fetch_add(1, Ordering::Relaxed));
    publishers.lock().await.insert(
        id.clone(),
        LivePublisherEntry {
            publisher,
            expires_at: Instant::now() + Duration::from_secs(live_ttl_secs.max(1)),
        },
    );
    out_tx
        .send(IpcFrame::LivePublishResult {
            request_id,
            id,
            ticket,
        })
        .await
        .map_err(|_| anyhow!("IPC client disconnected"))?;
    Ok(())
}

fn video_presets(quality: Option<&str>) -> Result<Vec<idfon_media::video::VideoPreset>> {
    use idfon_media::video::VideoPreset;
    match quality {
        None | Some("all") => Ok(vec![
            VideoPreset::P180,
            VideoPreset::P360,
            VideoPreset::P720,
        ]),
        Some("180p") | Some("low") => Ok(vec![VideoPreset::P180]),
        Some("360p") | Some("mid") | Some("medium") => Ok(vec![VideoPreset::P360]),
        Some("720p") | Some("high") => Ok(vec![VideoPreset::P720]),
        Some(value) => Err(anyhow!("unsupported live video quality {value}")),
    }
}

async fn cleanup_live_publishers(publishers: &LivePublishers) {
    let expired = {
        let now = Instant::now();
        let mut guard = publishers.lock().await;
        let ids = guard
            .iter()
            .filter(|(_, entry)| entry.expires_at <= now)
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        ids.into_iter()
            .filter_map(|id| guard.remove(&id).map(|entry| entry.publisher))
            .collect::<Vec<_>>()
    };
    for publisher in expired {
        let _ = tokio::task::spawn_blocking(move || publisher.stop()).await;
    }
}

async fn stop_all_live_publishers(publishers: &LivePublishers) {
    let entries = {
        let mut guard = publishers.lock().await;
        guard
            .drain()
            .map(|(_, entry)| entry.publisher)
            .collect::<Vec<_>>()
    };
    for publisher in entries {
        let _ = tokio::task::spawn_blocking(move || publisher.stop()).await;
    }
}

async fn handle_live_stop(
    request_id: String,
    id: String,
    publishers: &LivePublishers,
    out_tx: mpsc::Sender<IpcFrame>,
) -> Result<()> {
    let publisher = publishers
        .lock()
        .await
        .remove(&id)
        .ok_or_else(|| anyhow!("unknown live publisher {id}"))?
        .publisher;
    tokio::task::spawn_blocking(move || publisher.stop())
        .await
        .map_err(|error| anyhow!("stop live publisher: {error}"))?;
    out_tx
        .send(IpcFrame::LiveStopResult { request_id, id })
        .await
        .map_err(|_| anyhow!("IPC client disconnected"))?;
    Ok(())
}

/// Mint a subject-bound capability ticket for `subject` with the holder's key
/// and return it plus the holder's endpoint address. The agent (not a central
/// agency) signs its own card, freshly per request.
async fn handle_ticket_issue(
    request_id: String,
    subject: String,
    capabilities: Vec<String>,
    key: &SigningKey,
    transport: &IrohTransport,
    voice: &VoiceRoute,
    delegate_allow_file: Option<&str>,
    out_tx: mpsc::Sender<IpcFrame>,
) -> Result<()> {
    if voice.mode == VoiceMode::Delegated {
        if let Some(path) = delegate_allow_file {
            admit_caller_to(path, &subject);
        }
    }
    let mut grants = vec![Capability::MessageReceive];
    grants.extend(capabilities.into_iter().map(Capability::new));
    let ticket = issue_capability_ticket_with_voice(
        key,
        Some(subject),
        None,
        grants,
        None,
        format!("eve-ticket-{}", now_seconds()),
        Some(voice.clone()),
    );
    out_tx
        .send(IpcFrame::TicketIssueResult {
            request_id,
            ticket: serde_json::to_value(&ticket)?,
            endpoint_addr: serde_json::to_value(&transport.endpoint().addr())?,
        })
        .await
        .map_err(|_| anyhow!("IPC client disconnected"))?;
    Ok(())
}

async fn handle_blob_put(
    request_id: String,
    bytes_base64: String,
    store: &FsStore,
    endpoint: &Endpoint,
    out_tx: mpsc::Sender<IpcFrame>,
) -> Result<()> {
    let bytes = BASE64.decode(bytes_base64).context("decode blob data")?;
    if bytes.len() > MAX_BLOB_BYTES {
        return Err(anyhow!("blob exceeds {} byte limit", MAX_BLOB_BYTES));
    }
    let content = store
        .blobs()
        .add_slice(&bytes)
        .with_named_tag(format!("resource-{}", blake3::hash(&bytes)))
        .await?;
    let ticket = BlobTicket::new(endpoint.addr(), content.hash, content.format).to_string();
    out_tx
        .send(IpcFrame::BlobPutResult {
            request_id,
            ticket,
            size_bytes: bytes.len() as u64,
        })
        .await
        .map_err(|_| anyhow!("IPC client disconnected"))?;
    Ok(())
}

#[derive(Debug)]
enum HolderError {
    Auth(AuthError),
    CapabilityDenied,
    Unauthorized,
    ExpiredTicket,
    AgentCapabilityDenied,
    RateLimited,
    ResourceLimit,
    IdempotencyConflict,
}

impl HolderError {
    fn code(&self) -> &'static str {
        match self {
            Self::Auth(_) => "unauthorized",
            Self::CapabilityDenied | Self::ExpiredTicket | Self::AgentCapabilityDenied => {
                "capability_denied"
            }
            Self::Unauthorized => "unauthorized",
            Self::RateLimited => "rate_limited",
            Self::ResourceLimit => "resource_limit",
            Self::IdempotencyConflict => "idempotency_key_conflict",
        }
    }
}

impl std::fmt::Display for HolderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Auth(error) => write!(f, "message authentication failed: {error}"),
            Self::CapabilityDenied => write!(f, "message.receive capability denied"),
            Self::Unauthorized => write!(f, "sender is not allowed"),
            Self::ExpiredTicket => write!(f, "capability ticket is expired"),
            Self::AgentCapabilityDenied => write!(f, "agent.receive capability denied"),
            Self::RateLimited => write!(f, "peer message rate limit exceeded"),
            Self::ResourceLimit => write!(f, "holder resource limit exceeded"),
            Self::IdempotencyConflict => {
                write!(f, "idempotency key was reused with different content")
            }
        }
    }
}

impl std::error::Error for HolderError {}

fn validate_message<'a>(
    message: &'a MessageEnvelope,
    remote_endpoint_id: &str,
    allow: &[String],
    holder_peer_id: &str,
) -> std::result::Result<&'a CapabilityTicket, HolderError> {
    verify_message(message).map_err(HolderError::Auth)?;
    if message.sender.endpoint_id != remote_endpoint_id {
        return Err(HolderError::Unauthorized);
    }
    if !allow.is_empty() && !allow.iter().any(|peer| peer == &message.sender.peer_id) {
        return Err(HolderError::Unauthorized);
    }
    let Some(ticket) = &message.capability_ticket else {
        return Err(HolderError::CapabilityDenied);
    };
    verify_capability_ticket(ticket).map_err(HolderError::Auth)?;
    if ticket.issuer != holder_peer_id
        || ticket.subject.as_deref() != Some(message.sender.peer_id.as_str())
        || !ticket.capabilities.contains(&Capability::MessageReceive)
    {
        return Err(HolderError::CapabilityDenied);
    }
    if ticket.expires_at.as_deref().is_some_and(expiry_is_past) {
        return Err(HolderError::ExpiredTicket);
    }
    Ok(ticket)
}

fn expiry_is_past(value: &str) -> bool {
    if let Ok(seconds) = value.parse::<u64>() {
        return seconds <= now_seconds();
    }
    DateTime::parse_from_rfc3339(value)
        .map(|timestamp| timestamp <= Utc::now())
        .unwrap_or(true)
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

async fn read_frames<R>(mut reader: R, tx: mpsc::Sender<IpcFrame>)
where
    R: AsyncRead + Unpin,
{
    loop {
        match read_frame(&mut reader).await {
            Ok(Some(frame)) => {
                if tx.send(frame).await.is_err() {
                    break;
                }
            }
            Ok(None) => break,
            Err(error) => {
                tracing::warn!(target: "idfon.holder", error = %error, "IPC read failed");
                break;
            }
        }
    }
}

async fn write_frames<W>(mut writer: W, mut rx: mpsc::Receiver<IpcFrame>)
where
    W: AsyncWrite + Unpin,
{
    while let Some(frame) = rx.recv().await {
        if let Err(error) = write_frame(&mut writer, &frame).await {
            tracing::warn!(target: "idfon.holder", error = %error, "IPC write failed");
            break;
        }
    }
}

async fn read_frame<R>(reader: &mut R) -> Result<Option<IpcFrame>>
where
    R: AsyncRead + Unpin,
{
    let mut length = [0u8; 4];
    match reader.read_exact(&mut length).await {
        Ok(_) => {}
        Err(error) if error.kind() == ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error.into()),
    }
    let length = u32::from_le_bytes(length) as usize;
    if length > IPC_MAX_FRAME_BYTES {
        return Err(anyhow!("IPC frame is too large: {length} bytes"));
    }
    let mut payload = vec![0u8; length];
    reader
        .read_exact(&mut payload)
        .await
        .context("read IPC payload")?;
    Ok(Some(
        serde_json::from_slice(&payload).context("decode IPC JSON")?,
    ))
}

async fn write_frame<W>(writer: &mut W, frame: &IpcFrame) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    let payload = serde_json::to_vec(frame).context("encode IPC JSON")?;
    if payload.len() > IPC_MAX_FRAME_BYTES {
        return Err(anyhow!("IPC frame is too large: {} bytes", payload.len()));
    }
    writer
        .write_all(&(payload.len() as u32).to_le_bytes())
        .await?;
    writer.write_all(&payload).await?;
    writer.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use idfon_core::{generate_identity, issue_capability_ticket, sign_message_with_ticket};
    use tokio::io::duplex;

    #[test]
    fn generated_message_ids_are_unique_and_prefixed() {
        let a = next_message_id("eve_reply_");
        let b = next_message_id("eve_reply_");
        assert!(a.starts_with("eve_reply_"));
        assert_ne!(a, b);
        // The per-process token keeps ids distinct from a bare counter, so a
        // restarted holder cannot reissue an id a receiver already saw.
        assert_ne!(a, "eve_reply_1");
    }

    #[test]
    fn voice_route_is_derived_from_live_params() {
        // No live config: a text-only holder, and callers drive on-device STT/TTS.
        let cascade = voice_route_from_live_params(&serde_json::Value::Null);
        assert_eq!(cascade.mode, VoiceMode::ClientCascade);

        // A live config but no explicit `voice`: a native full-duplex holder.
        let native = voice_route_from_live_params(&serde_json::json!({
            "model": "openai/gpt-live-1",
            "audio": "pcm24k"
        }));
        assert_eq!(native.mode, VoiceMode::NativeDuplex);
        assert_eq!(native.audio.as_deref(), Some("pcm24k"));
        assert_eq!(native.model.as_deref(), Some("openai/gpt-live-1"));

        // An explicit `voice_route` block wins (e.g. a delegated translator).
        let delegated = voice_route_from_live_params(&serde_json::json!({
            "voice_route": { "mode": "delegated", "delegate": { "peer_id": "voice-agent" } }
        }));
        assert_eq!(delegated.mode, VoiceMode::Delegated);
        assert_eq!(
            delegated.delegate.as_ref().map(|delegate| delegate.peer_id.as_str()),
            Some("voice-agent")
        );
    }

    #[test]
    fn validation_requires_a_holder_ticket_and_real_remote_endpoint() {
        let holder = generate_identity();
        let sender = generate_identity();
        let sender_id = peer_id(&sender);
        let holder_id = peer_id(&holder);
        let ticket = issue_capability_ticket(
            &holder,
            Some(sender_id.clone()),
            vec![Capability::MessageReceive],
            None,
            "ticket-1",
        );
        let message = sign_message_with_ticket(
            &sender,
            sender_id.clone(),
            "msg-1",
            MessageContent::Text {
                text: "hello".into(),
            },
            "key-1",
            None,
            Some(ticket),
        )
        .unwrap();
        assert!(validate_message(&message, &sender_id, &[], &holder_id).is_ok());

        let no_ticket = sign_message(
            &sender,
            sender_id.clone(),
            "msg-2",
            MessageContent::Text {
                text: "hello".into(),
            },
            "key-2",
            None,
        )
        .unwrap();
        assert!(matches!(
            validate_message(&no_ticket, &sender_id, &[], &holder_id),
            Err(HolderError::CapabilityDenied)
        ));
        assert!(matches!(
            validate_message(&message, "wrong-endpoint", &[], &holder_id),
            Err(HolderError::Unauthorized)
        ));

        let expired = issue_capability_ticket(
            &holder,
            Some(sender_id.clone()),
            vec![Capability::MessageReceive],
            Some("2000-01-01T00:00:00Z".into()),
            "ticket-2",
        );
        let expired_message = sign_message_with_ticket(
            &sender,
            sender_id.clone(),
            "msg-3",
            MessageContent::Text {
                text: "hello".into(),
            },
            "key-3",
            None,
            Some(expired),
        )
        .unwrap();
        assert!(matches!(
            validate_message(&expired_message, &sender_id, &[], &holder_id),
            Err(HolderError::ExpiredTicket)
        ));
    }

    #[tokio::test]
    async fn rate_limit_is_per_peer_and_bounded() {
        let limits = RateLimits::default();
        for _ in 0..MAX_MESSAGES_PER_PEER_PER_MINUTE {
            assert!(admit_message(&limits, "peer-a").await);
        }
        assert!(!admit_message(&limits, "peer-a").await);
        assert!(admit_message(&limits, "peer-b").await);
    }

    #[test]
    fn input_response_extracts_json_payload() {
        let encoded = BASE64.encode(r#"[{"requestId":"req","optionId":"approve"}]"#);
        let text = format!("IDFON-HITL-RESPONSE/1\npayload={encoded}");
        assert_eq!(
            parse_input_response(&text),
            Some(serde_json::json!([{"requestId": "req", "optionId": "approve"}]))
        );
    }

    #[test]
    fn data_envelope_extracts_blob_ticket_and_size() {
        assert_eq!(
            parse_data_envelope("IDFON-DATA/1\nticket=blob-ticket\nsize=42"),
            Some(("blob-ticket".into(), Some(42)))
        );
        assert_eq!(parse_data_envelope("hello"), None);
    }

    #[test]
    fn recording_envelope_extracts_blob_ticket() {
        let text = "IDFON-RECORDING/1\nid=x\ncodec=opus\nchannels=1\nsample_rate=48000\nduration_ms=1200\nsender_id=peer\nticket=blob-rec";
        assert_eq!(
            parse_data_envelope(text),
            Some(("blob-rec".into(), None))
        );
    }

    #[test]
    fn a2a_envelope_round_trips_and_rejects_plain_text() {
        let trace = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
        let encoded = encode_a2a_envelope(1, "hello\npeer", Some(trace), Some("correlate"));
        assert_eq!(
            parse_a2a_envelope(&encoded),
            Some(A2aEnvelope {
                depth: 1,
                text: "hello\npeer".into(),
                trace: Some(trace.into()),
                telemetry: Some("correlate".into()),
            })
        );
        // Older payloads without trace/telemetry still parse.
        assert_eq!(
            parse_a2a_envelope(&encode_a2a_envelope(1, "x", None, None)),
            Some(A2aEnvelope {
                depth: 1,
                text: "x".into(),
                trace: None,
                telemetry: None,
            })
        );
        assert_eq!(parse_a2a_envelope("hello"), None);
    }

    #[test]
    fn status_envelope_round_trips_and_rejects_plain_text() {
        let encoded =
            encode_status_envelope("turn.cancelled", &serde_json::json!({"reason": "user"}))
                .unwrap();
        assert_eq!(
            parse_status_envelope(&encoded),
            Some((
                "turn.cancelled".into(),
                serde_json::json!({"reason": "user"}),
            ))
        );
        assert_eq!(parse_status_envelope("hello"), None);
    }

    #[test]
    fn data_envelope_ignores_a_trailing_reference() {
        // A voice memo can carry a trailing reference envelope (ask about an
        // artifact region); attachment parsing must stop at its header.
        let combined = "IDFON-RECORDING/1\nid=a\ncodec=pcm\nduration_ms=2500\nticket=tkt-2\nIDFON-REF/1\n{\"text\":\"\",\"refs\":[]}";
        assert_eq!(parse_data_envelope(combined), Some(("tkt-2".into(), None)));
        assert_eq!(
            parse_data_envelope("IDFON-DATA/1\nticket=t\nsize=12\n"),
            Some(("t".into(), Some(12)))
        );
        assert_eq!(parse_data_envelope("plain text"), None);
    }

    #[tokio::test]
    async fn ipc_frame_round_trips_with_little_endian_length() {
        let frame = IpcFrame::TurnIn {
            message_id: "msg-1".into(),
            peer_id: "peer".into(),
            endpoint_id: "endpoint".into(),
            idempotency_key: "key".into(),
            conversation: Some("thread".into()),
            text: "hello".into(),
            blob_ticket: None,
            size_bytes: None,
            a2a_depth: None,
            capabilities: None,
            source: None,
        };
        let (mut writer, mut reader) = duplex(4096);
        write_frame(&mut writer, &frame).await.unwrap();
        drop(writer);
        assert!(
            matches!(read_frame(&mut reader).await.unwrap(), Some(IpcFrame::TurnIn { text, .. }) if text == "hello")
        );
    }

    #[tokio::test]
    async fn ticket_issue_frame_round_trips() {
        let frame = IpcFrame::TicketIssue {
            request_id: "r1".into(),
            subject: "peer-a".into(),
            capabilities: vec!["agent.receive".into()],
        };
        let (mut writer, mut reader) = duplex(4096);
        write_frame(&mut writer, &frame).await.unwrap();
        drop(writer);
        match read_frame(&mut reader).await.unwrap() {
            Some(IpcFrame::TicketIssue {
                request_id,
                subject,
                capabilities,
            }) => {
                assert_eq!(request_id, "r1");
                assert_eq!(subject, "peer-a");
                assert_eq!(capabilities, vec!["agent.receive".to_string()]);
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn allow_file_parses_dedupes_and_missing_is_empty() {
        let dir = std::env::temp_dir().join(format!("eve-allow-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("allow");
        std::fs::write(&path, "peer-a\n\n peer-b \npeer-a\n").unwrap();
        assert_eq!(load_allow_file(&path), vec!["peer-a", "peer-b"]);
        assert!(load_allow_file(&dir.join("missing")).is_empty());
        // Static --allow entries survive the file reload (union, not replace).
        assert_eq!(
            merge_allow(&["daemon".to_string()], &load_allow_file(&path)),
            vec!["daemon", "peer-a", "peer-b"]
        );
    }

    #[test]
    fn strip_envelopes_keeps_only_spoken_text() {
        assert_eq!(strip_envelopes("Pong."), "Pong.");
        assert_eq!(
            strip_envelopes("Here you go.\nIDFON-ARTIFACT/1\n{\"a\":1}"),
            "Here you go."
        );
        assert_eq!(strip_envelopes("IDFON-DATA/1\n{}"), "");
    }
}
