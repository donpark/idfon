//! Versioned logical API types shared by the daemon and clients.

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;

pub type RequestId = String;
pub type OperationId = String;
pub type EventId = String;
pub type Cursor = String;
pub type MessageId = String;

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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MessageAck {
    pub message_id: MessageId,
    pub status: AckStatus,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Peer {
    pub id: String,
    pub name: String,
    pub endpoint_id: Option<String>,
    #[serde(default)]
    pub endpoint_addr: Option<String>,
    pub aliases: Vec<String>,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    MessageSend,
    MessageReceive,
    VoiceMessageSend,
    VoiceMessageReceive,
    LiveAudioPublish,
    LiveAudioSubscribe,
    RecordingFetch,
    RecordingRetain,
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
            version: 2,
            id: "r".into(),
            method: "status".into(),
            params: serde_json::Value::Null,
        };
        assert_eq!(
            validate_request(&request),
            Err(ProtocolError::InvalidVersion(2))
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
                    next: vec!["nufon peer status alice".into()],
                },
            },
        };
        let value: serde_json::Value =
            serde_json::from_slice(&encode_json(&response).unwrap()).unwrap();
        assert_eq!(value["error"]["code"], "peer_offline");
        assert_eq!(value["ok"], false);
    }
}
