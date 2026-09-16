//! Versioned logical API types shared by the daemon and clients.

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const PROTOCOL_VERSION: u16 = 2;
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;

pub type RequestId = String;
pub type OperationId = String;
pub type EventId = String;
pub type Cursor = String;
pub type MessageId = String;
pub type MediaId = String;
pub type ResourceId = String;

/// Transport-independent proof-bearing peer identity.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PeerAuth {
    pub peer_id: String,
    pub endpoint_id: String,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MessageContent {
    Text { text: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MessageSend {
    pub to: String,
    pub content: MessageContent,
    pub sender: PeerAuth,
    pub idempotency_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MessageEnvelope {
    pub message_id: MessageId,
    pub sender: PeerAuth,
    pub content: MessageContent,
    pub idempotency_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capability_ticket: Option<CapabilityTicket>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MessageAck {
    pub message_id: MessageId,
    pub status: AckStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MediaResource {
    #[serde(default)]
    pub identity: String,
    pub resource_id: ResourceId,
    pub media_id: MediaId,
    pub kind: MediaKind,
    pub codec: Option<String>,
    pub size_bytes: u64,
    pub duration_ms: Option<u64>,
    pub content_hash: Option<String>,
    #[serde(default)]
    pub blob_ticket: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    File,
    Recording,
    LiveAudio,
    LiveVideo,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MediaSession {
    pub session_id: String,
    pub identity: String,
    pub peer: String,
    pub conversation: Option<String>,
    pub kind: MediaKind,
    pub capability: Capability,
    pub active: bool,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MediaOperation {
    Upload,
    Download,
    Publish,
    Subscribe,
    Stop,
    Delete,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AckStatus {
    Accepted,
    Duplicate,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Request {
    pub version: u16,
    pub id: RequestId,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Response {
    pub version: u16,
    pub id: RequestId,
    pub ok: bool,
    #[serde(flatten)]
    pub body: ResponseBody,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
pub enum ResponseBody {
    Success {
        operation: String,
        result: serde_json::Value,
    },
    Failure {
        operation: String,
        error: ApiError,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ApiError {
    pub code: ErrorCode,
    pub message: String,
    pub retryable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_after_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub next: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidJson,
    InvalidVersion,
    FrameTooLarge,
    UnknownMethod,
    InvalidRequest,
    PeerOffline,
    AmbiguousPeer,
    Unauthorized,
    CapabilityDenied,
    IdempotencyKeyConflict,
    CursorTooOld,
    Timeout,
    Internal,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OperationStatus {
    Accepted,
    Resolving,
    Connecting,
    Queued,
    Transmitting,
    RemoteAck,
    Delivered,
    Failed,
    Expired,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Operation {
    #[serde(default)]
    pub identity: String,
    pub operation_id: OperationId,
    pub method: String,
    pub status: OperationStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_fingerprint: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Event {
    pub event_id: EventId,
    pub cursor: Cursor,
    pub r#type: String,
    pub timestamp: String,
    pub identity: String,
    pub data: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Identity {
    pub id: String,
    pub name: String,
    pub endpoint_id: Option<String>,
    #[serde(default)]
    pub public_key: Option<String>,
    pub active: bool,
}

/// How an incoming call for this connection is surfaced by the shell.
/// Default is `Bar` (Live Activity Bar) until CallKit is available.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum IncomingCallMode {
    #[default]
    Bar,
    CallKit,
}

/// One device endpoint of a peer's account. `Peer::endpoint_id`/`endpoint_addr`
/// stay the primary (legacy) device; `devices` are the additional devices a
/// multi-device account is reachable on.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PeerDevice {
    pub endpoint_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub endpoint_addr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// Advisory sender-side routing metadata; not an authorization boundary.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_class: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryMode {
    #[default]
    Failover,
    One,
    All,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct DeliveryPolicy {
    #[serde(default)]
    pub mode: DeliveryMode,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub endpoint_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_class: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Peer {
    pub id: String,
    #[serde(default)]
    pub identity: String,
    pub name: String,
    pub endpoint_id: Option<String>,
    #[serde(default)]
    pub endpoint_addr: Option<String>,
    /// Additional device endpoints beyond the primary pair above. Empty for
    /// single-device peers (every peer before multi-device enrollment).
    #[serde(default)]
    pub devices: Vec<PeerDevice>,
    pub aliases: Vec<String>,
    #[serde(default)]
    pub call_mode: IncomingCallMode,
}

impl Peer {
    /// Every dialable `(endpoint_id, endpoint_addr JSON)` for this peer: the
    /// primary pair first, then `devices`, deduped by endpoint id. Entries
    /// without an address are skipped.
    pub fn dial_targets(&self) -> Vec<(String, String)> {
        self.dial_targets_with(None)
    }

    /// Selects concrete devices for a sender policy. Empty filters mean all
    /// dialable devices; `one` is enforced by the transport caller.
    pub fn dial_targets_with(&self, policy: Option<&DeliveryPolicy>) -> Vec<(String, String)> {
        fn add(
            targets: &mut Vec<(String, String)>,
            endpoint_id: Option<&str>,
            endpoint_addr: Option<&str>,
        ) {
            if let (Some(endpoint_id), Some(endpoint_addr)) = (endpoint_id, endpoint_addr) {
                if !targets.iter().any(|(known, _)| known == endpoint_id) {
                    targets.push((endpoint_id.to_string(), endpoint_addr.to_string()));
                }
            }
        }
        let mut targets = Vec::new();
        let primary_selected = policy.is_none_or(|policy| {
            policy.device_class.is_none()
                && (policy.endpoint_ids.is_empty()
                    || self
                        .endpoint_id
                        .as_deref()
                        .is_some_and(|id| policy.endpoint_ids.iter().any(|wanted| wanted == id)))
        });
        if primary_selected {
            add(
                &mut targets,
                self.endpoint_id.as_deref(),
                self.endpoint_addr.as_deref(),
            );
        }
        for device in &self.devices {
            let selected = policy.is_none_or(|policy| {
                (policy.endpoint_ids.is_empty()
                    || policy
                        .endpoint_ids
                        .iter()
                        .any(|id| id == &device.endpoint_id))
                    && policy
                        .device_class
                        .as_deref()
                        .is_none_or(|class| device.device_class.as_deref() == Some(class))
            });
            if selected {
                add(
                    &mut targets,
                    Some(device.endpoint_id.as_str()),
                    device.endpoint_addr.as_deref(),
                );
            }
        }
        if let Some(policy) = policy {
            if !policy.endpoint_ids.is_empty() {
                targets.retain(|(id, _)| policy.endpoint_ids.iter().any(|wanted| wanted == id));
            }
        }
        targets
    }

    /// Whether `endpoint_id` is one of this peer's devices (primary or extra).
    pub fn knows_endpoint(&self, endpoint_id: &str) -> bool {
        self.endpoint_id.as_deref() == Some(endpoint_id)
            || self
                .devices
                .iter()
                .any(|device| device.endpoint_id == endpoint_id)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CapabilityTicket {
    pub issuer: String,
    pub subject: Option<String>,
    pub capabilities: Vec<Capability>,
    pub expires_at: Option<String>,
    pub ticket_id: String,
    pub signature: String,
}

/// Canonical Idfon device/contact ticket. `endpoint_addr` is serialized
/// transport metadata; account/device fields are identity and routing hints.
/// Legacy raw EndpointAddr JSON remains accepted by daemon import paths.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContactTicket {
    pub version: u16,
    pub account_id: String,
    pub endpoint_id: String,
    pub endpoint_addr: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_class: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub capabilities: Vec<String>,
}

/// Net-new MCP contact ticket: everything the user side needs to add an agent
/// as a contact without a live connection. `discover` is an optional cache of
/// the agent's `server/discover` result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct McpContactTicket {
    /// Peer endpoint address as JSON text (iroh `EndpointAddr`), used to dial.
    pub transport: String,
    pub peer: McpPeer,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub discover: Option<McpDiscover>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct McpPeer {
    /// Stable account/virtual identity. Absent on legacy endpoint-only tickets.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
    pub endpoint_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// Cached `server/discover` result. `serverInfo` is **unverified** (reported by
/// the agent, not attested) and must only ever be displayed.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct McpDiscover {
    #[serde(default)]
    pub supported_versions: Vec<String>,
    #[serde(default)]
    pub capabilities: serde_json::Value,
    #[serde(default)]
    pub server_info: serde_json::Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ttl_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_scope: Option<String>,
    #[serde(default)]
    pub cached_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct McpDiscoveryRecord {
    pub peer_id: String,
    pub identity: String,
    pub discover: McpDiscover,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CapabilityGrant {
    pub capability: Capability,
    pub identity: String,
    pub subject: String,
    pub conversation: Option<String>,
    pub active_at: String,
    pub expires_at: Option<String>,
    pub revision: u64,
    pub revoked_at: Option<String>,
}

/// A local room: a `conversation` topic plus the peers this identity delivers
/// to. Membership is local state, never shared or authoritative — two peers may
/// disagree about who is present (see `docs/chatrooms.md`). 1:1 has no `Room`;
/// it is the degenerate case (`conversation = None`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Room {
    pub id: String,
    pub identity: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Resolved peer ids (not names/aliases) so a rename cannot silently drop a
    /// recipient.
    #[serde(default)]
    pub members: Vec<String>,
}

/// An open, namespaced capability. Wire names are dotted strings (e.g.
/// `message.send`, `mcp.transport`); a provider may define its own without a
/// protocol change. The associated constants are the built-in names.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(transparent)]
pub struct Capability(pub std::borrow::Cow<'static, str>);

#[allow(non_upper_case_globals)]
impl Capability {
    pub const MessageSend: Capability = Capability(std::borrow::Cow::Borrowed("message.send"));
    pub const MessageReceive: Capability =
        Capability(std::borrow::Cow::Borrowed("message.receive"));
    pub const VoiceMessageSend: Capability =
        Capability(std::borrow::Cow::Borrowed("voice.message.send"));
    pub const VoiceMessageReceive: Capability =
        Capability(std::borrow::Cow::Borrowed("voice.message.receive"));
    pub const LiveAudioPublish: Capability =
        Capability(std::borrow::Cow::Borrowed("live.audio.publish"));
    pub const LiveAudioSubscribe: Capability =
        Capability(std::borrow::Cow::Borrowed("live.audio.subscribe"));
    pub const RecordingFetch: Capability =
        Capability(std::borrow::Cow::Borrowed("recording.fetch"));
    pub const RecordingRetain: Capability =
        Capability(std::borrow::Cow::Borrowed("recording.retain"));
    /// May use the peer's `idfon/mcp/1` transport (grants gate each direction).
    pub const McpTransport: Capability = Capability(std::borrow::Cow::Borrowed("mcp.transport"));

    pub fn new(value: impl Into<String>) -> Self {
        Capability(std::borrow::Cow::Owned(value.into()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// The one shared vocabulary for an invoked capability's result. Kept
/// deliberately small: text, a rendered view, a blob or stream ticket, or an
/// error.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InvocationResult {
    Text { text: String },
    Render { view: serde_json::Value },
    BlobTicket { blob_ticket: String },
    StreamTicket { stream_ticket: String },
    Error { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PolicyDiagnostic {
    pub path: String,
    pub code: String,
    pub severity: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LocalPolicy {
    pub id: String,
    pub identity: String,
    pub subject: String,
    pub mode: String,
    pub delivery: String,
    pub notify: bool,
    pub auto_accept: bool,
    pub interrupt: bool,
    pub record: bool,
    pub expires_at: Option<String>,
    #[serde(default)]
    pub schedule_start: Option<u8>,
    #[serde(default)]
    pub schedule_end: Option<u8>,
    pub revision: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Session {
    pub id: String,
    pub app_id: String,
    pub identity: String,
    pub peer: Option<String>,
    pub conversation: Option<String>,
    pub capabilities: Vec<Capability>,
    pub expires_at: String,
    pub revoked: bool,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProtocolError {
    #[error("frame is too large")]
    FrameTooLarge,
    #[error("invalid protocol version {0}")]
    InvalidVersion(u16),
}

pub fn validate_request(request: &Request) -> Result<(), ProtocolError> {
    if request.version != PROTOCOL_VERSION {
        return Err(ProtocolError::InvalidVersion(request.version));
    }
    Ok(())
}

pub fn encode_json<T: Serialize>(value: &T) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(value)
}

pub fn decode_request(bytes: &[u8]) -> Result<Request, serde_json::Error> {
    serde_json::from_slice(bytes)
}

/// Encodes one complete IPC frame: big-endian u32 length followed by JSON.
pub fn encode_frame<T: Serialize>(value: &T) -> Result<Vec<u8>, FrameError> {
    let payload = encode_json(value).map_err(FrameError::Json)?;
    if payload.len() > MAX_FRAME_BYTES || payload.len() > u32::MAX as usize {
        return Err(FrameError::TooLarge(payload.len()));
    }
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(&payload);
    Ok(frame)
}

pub fn decode_frame<T: for<'de> Deserialize<'de>>(frame: &[u8]) -> Result<T, FrameError> {
    if frame.len() < 4 {
        return Err(FrameError::Truncated);
    }
    let length = u32::from_be_bytes(frame[..4].try_into().unwrap()) as usize;
    if length > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(length));
    }
    if frame.len() != length + 4 {
        return Err(FrameError::LengthMismatch {
            declared: length,
            actual: frame.len() - 4,
        });
    }
    serde_json::from_slice(&frame[4..]).map_err(FrameError::Json)
}

#[derive(Debug, Error)]
pub enum FrameError {
    #[error("frame is truncated")]
    Truncated,
    #[error("frame length {0} exceeds the limit")]
    TooLarge(usize),
    #[error("frame length mismatch: declared {declared}, received {actual}")]
    LengthMismatch { declared: usize, actual: usize },
    #[error("invalid JSON: {0}")]
    Json(serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_round_trip_matches_contract() {
        let request = Request {
            version: PROTOCOL_VERSION,
            id: "req_1".into(),
            method: "message.send".into(),
            params: serde_json::json!({"to": "alice", "content": {"type": "text", "text": "hello"}}),
        };
        let json = encode_json(&request).unwrap();
        assert_eq!(decode_request(&json).unwrap(), request);
    }

    #[test]
    fn rejects_wrong_version() {
        let request = Request {
            version: PROTOCOL_VERSION + 1,
            id: "r".into(),
            method: "status".into(),
            params: serde_json::Value::Null,
        };
        assert_eq!(
            validate_request(&request),
            Err(ProtocolError::InvalidVersion(PROTOCOL_VERSION + 1))
        );
    }

    #[test]
    fn capability_names_are_open_and_round_trip() {
        let built_in = Capability::MessageSend;
        assert_eq!(encode_json(&built_in).unwrap(), br#""message.send""#);
        assert_eq!(
            serde_json::from_str::<Capability>("\"vendor.custom.thing\"").unwrap(),
            Capability::new("vendor.custom.thing")
        );
        assert_eq!(built_in.as_str(), "message.send");
    }

    #[test]
    fn invocation_result_vocabulary_round_trips() {
        for result in [
            InvocationResult::Text { text: "hi".into() },
            InvocationResult::Render {
                view: serde_json::json!({"kind": "card"}),
            },
            InvocationResult::BlobTicket {
                blob_ticket: "blob1".into(),
            },
            InvocationResult::StreamTicket {
                stream_ticket: "stream1".into(),
            },
            InvocationResult::Error {
                message: "nope".into(),
            },
        ] {
            let json = encode_json(&result).unwrap();
            assert_eq!(
                serde_json::from_slice::<InvocationResult>(&json).unwrap(),
                result
            );
        }
    }

    #[test]
    fn media_resource_and_session_round_trip() {
        let value = (
            MediaResource {
                identity: "default".into(),
                resource_id: "res_1".into(),
                media_id: "media_1".into(),
                kind: MediaKind::Recording,
                codec: Some("opus".into()),
                size_bytes: 42,
                duration_ms: Some(1000),
                content_hash: Some("hash".into()),
                blob_ticket: None,
            },
            MediaSession {
                session_id: "session_1".into(),
                identity: "default".into(),
                peer: "alice".into(),
                conversation: None,
                kind: MediaKind::Recording,
                capability: Capability::RecordingFetch,
                active: true,
                created_at: "0".into(),
            },
        );
        let json = encode_json(&value).unwrap();
        assert_eq!(
            serde_json::from_slice::<(MediaResource, MediaSession)>(&json).unwrap(),
            value
        );
    }

    #[test]
    fn message_envelope_round_trips_with_authentication_fields() {
        let message = MessageEnvelope {
            message_id: "msg_1".into(),
            sender: PeerAuth {
                peer_id: "alice".into(),
                endpoint_id: "ep_alice".into(),
                signature: "sig".into(),
            },
            content: MessageContent::Text {
                text: "hello".into(),
            },
            idempotency_key: "hello-1".into(),
            capability_ticket: None,
            conversation: Some("conversation-1".into()),
        };
        let frame = encode_frame(&message).unwrap();
        assert_eq!(decode_frame::<MessageEnvelope>(&frame).unwrap(), message);
    }

    #[test]
    fn frame_decoder_rejects_truncated_and_mismatched_frames() {
        assert!(matches!(
            decode_frame::<Request>(&[0, 0, 0]),
            Err(FrameError::Truncated)
        ));
        let frame = [0, 0, 0, 5, b'{', b'}'];
        assert!(matches!(
            decode_frame::<Request>(&frame),
            Err(FrameError::LengthMismatch {
                declared: 5,
                actual: 2
            })
        ));
    }

    #[test]
    fn failure_envelope_is_stable() {
        let response = Response {
            version: PROTOCOL_VERSION,
            id: "req_1".into(),
            ok: false,
            body: ResponseBody::Failure {
                operation: "message.send".into(),
                error: ApiError {
                    code: ErrorCode::PeerOffline,
                    message: "offline".into(),
                    retryable: true,
                    retry_after_ms: Some(5000),
                    next: vec!["idfon peer status alice".into()],
                },
            },
        };
        let value: serde_json::Value =
            serde_json::from_slice(&encode_json(&response).unwrap()).unwrap();
        assert_eq!(value["error"]["code"], "peer_offline");
        assert_eq!(value["ok"], false);
    }
}
