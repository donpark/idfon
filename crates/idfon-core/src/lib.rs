//! Domain security helpers kept independent from transport details.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use getrandom::{rand_core::UnwrapErr, SysRng};
use idfon_protocol::{
    Capability, CapabilityTicket, MessageContent, MessageEnvelope, PeerAuth, VoiceRoute,
};
use serde::Serialize;
use thiserror::Error;

pub mod path;
// Gossip + tokio I/O are native-only; the wasm build (Cloudflare Worker) uses
// only the security helpers in this file.
#[cfg(not(target_family = "wasm"))]
pub mod transport;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum AuthError {
    #[error("invalid peer ID encoding")]
    InvalidPeerId,
    #[error("invalid signature encoding")]
    InvalidSignature,
    #[error("message authentication failed")]
    VerificationFailed,
    #[error("message authentication serialization failed")]
    Serialization,
}

/// Generates a new Ed25519 identity key. Keep the signing key in secure storage.
pub fn generate_identity() -> SigningKey {
    SigningKey::generate(&mut UnwrapErr(SysRng))
}

/// Returns the stable hexadecimal public-key identity used as `PeerAuth.peer_id`.
pub fn peer_id(key: &SigningKey) -> String {
    encode_hex(key.verifying_key().as_bytes())
}

/// Mint a W3C-traceparent-shaped correlation id (`00-<32hex>-<16hex>-01`).
///
/// Not cryptographically meaningful — the trace is an unsigned convenience id,
/// never an authority (see `docs/observability.md`). Unique per call across
/// processes via time + pid + a process-local counter, spread by blake3.
pub fn new_traceparent() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let digest = blake3::hash(format!("{}:{}:{}", nanos, std::process::id(), seq).as_bytes());
    let bytes = digest.as_bytes();
    format!(
        "00-{}-{}-01",
        encode_hex(&bytes[..16]),
        encode_hex(&bytes[16..24])
    )
}

/// Stable, non-revealing account handle: `blake3(account_id)` in lowercase hex.
///
/// Every contact already carries `account_id`, so the handle is derivable rather
/// than carried: `idfon://<handle>` addresses the account without exposing the
/// account key. It is 32 bytes / 64 hex — the same shape as a peer id — which is
/// fine because refs are resolved by matching a field set, not by dispatching on
/// shape (see the daemon's `resolve_peer_id`).
pub fn account_alias(account_id: &str) -> String {
    encode_hex(blake3::hash(account_id.as_bytes()).as_bytes())
}

/// The short, DNS-safe host form of an endpoint id: z-base-32 (52 chars), the
/// encoding pkarr/iroh use for endpoint ids in DNS names. The 64-char hex form
/// exceeds the 63-octet DNS label limit, so `<ref>` hostnames use this.
pub fn endpoint_ref(id: &iroh::EndpointId) -> String {
    id.to_z32()
}

/// Parses an endpoint reference: 64-char hex, or 52-char z-base-32
/// (case-insensitive, since DNS is). Length disambiguates the alphabets; other
/// forms (aliases) return `None`.
pub fn parse_endpoint_ref(value: &str) -> Option<iroh::EndpointId> {
    let value = value.trim();
    match value.len() {
        64 => value.parse::<iroh::EndpointId>().ok(),
        52 => iroh::EndpointId::from_z32(&value.to_ascii_lowercase()).ok(),
        _ => value.parse::<iroh::EndpointId>().ok(),
    }
}

pub fn encode_signing_key(key: &SigningKey) -> String {
    encode_hex(&key.to_bytes())
}

pub fn signing_key_bytes(key: &SigningKey) -> [u8; 32] {
    key.to_bytes()
}

pub fn decode_signing_key(value: &str) -> Option<SigningKey> {
    decode_fixed::<32>(value).map(|bytes| SigningKey::from_bytes(&bytes))
}

/// Signs a logical message. The endpoint ID is included to bind the proof to
/// the endpoint that claims to represent the peer.
pub fn sign_message(
    key: &SigningKey,
    endpoint_id: impl Into<String>,
    message_id: impl Into<String>,
    content: MessageContent,
    idempotency_key: impl Into<String>,
    conversation: Option<String>,
) -> Result<MessageEnvelope, AuthError> {
    sign_message_with_ticket(
        key,
        endpoint_id,
        message_id,
        content,
        idempotency_key,
        conversation,
        None,
    )
}

pub fn sign_message_with_ticket(
    key: &SigningKey,
    endpoint_id: impl Into<String>,
    message_id: impl Into<String>,
    content: MessageContent,
    idempotency_key: impl Into<String>,
    conversation: Option<String>,
    capability_ticket: Option<CapabilityTicket>,
) -> Result<MessageEnvelope, AuthError> {
    let sender = PeerAuth {
        peer_id: peer_id(key),
        endpoint_id: endpoint_id.into(),
        signature: String::new(),
    };
    let unsigned = MessageEnvelope {
        message_id: message_id.into(),
        sender: sender.clone(),
        content,
        idempotency_key: idempotency_key.into(),
        capability_ticket,
        conversation,
        trace: None,
        telemetry: None,
        context: None,
    };
    let signature = key.sign(&auth_bytes(&unsigned)?);
    Ok(MessageEnvelope {
        sender: PeerAuth {
            signature: encode_hex(&signature.to_bytes()),
            ..sender
        },
        ..unsigned
    })
}

pub fn issue_capability_ticket(
    key: &SigningKey,
    subject: Option<String>,
    capabilities: Vec<Capability>,
    expires_at: Option<String>,
    ticket_id: impl Into<String>,
) -> CapabilityTicket {
    issue_capability_ticket_for_conversation(
        key,
        subject,
        None,
        capabilities,
        expires_at,
        ticket_id,
    )
}

pub fn issue_capability_ticket_for_conversation(
    key: &SigningKey,
    subject: Option<String>,
    conversation: Option<String>,
    capabilities: Vec<Capability>,
    expires_at: Option<String>,
    ticket_id: impl Into<String>,
) -> CapabilityTicket {
    issue_capability_ticket_with_voice(
        key,
        subject,
        conversation,
        capabilities,
        expires_at,
        ticket_id,
        None,
        None,
    )
}

/// Like [`issue_capability_ticket`], but bounds the ticket to a path prefix
/// (e.g. `/fs/public`). The prefix is signed, so it cannot be widened.
pub fn issue_capability_ticket_scoped(
    key: &SigningKey,
    subject: Option<String>,
    capabilities: Vec<Capability>,
    expires_at: Option<String>,
    ticket_id: impl Into<String>,
    path_scope: Option<String>,
) -> CapabilityTicket {
    issue_capability_ticket_with_voice(
        key,
        subject,
        None,
        capabilities,
        expires_at,
        ticket_id,
        None,
        path_scope,
    )
}

/// Like [`issue_capability_ticket_for_conversation`], but also signs a
/// [`VoiceRoute`] describing how the issuer wants voice carried.
#[allow(clippy::too_many_arguments)]
pub fn issue_capability_ticket_with_voice(
    key: &SigningKey,
    subject: Option<String>,
    conversation: Option<String>,
    capabilities: Vec<Capability>,
    expires_at: Option<String>,
    ticket_id: impl Into<String>,
    voice: Option<VoiceRoute>,
    path_scope: Option<String>,
) -> CapabilityTicket {
    let mut ticket = CapabilityTicket {
        issuer: peer_id(key),
        subject,
        conversation,
        path_scope,
        capabilities,
        expires_at,
        ticket_id: ticket_id.into(),
        voice,
        signature: String::new(),
    };
    ticket.signature = encode_hex(
        &key.sign(&serde_json::to_vec(&ticket_unsigned(&ticket)).unwrap())
            .to_bytes(),
    );
    ticket
}

pub fn verify_capability_ticket(ticket: &CapabilityTicket) -> Result<(), AuthError> {
    let public = decode_fixed::<32>(&ticket.issuer).ok_or(AuthError::InvalidPeerId)?;
    let key = VerifyingKey::from_bytes(&public).map_err(|_| AuthError::InvalidPeerId)?;
    let sig = decode_fixed::<64>(&ticket.signature).ok_or(AuthError::InvalidSignature)?;
    key.verify(
        &serde_json::to_vec(&ticket_unsigned(ticket)).map_err(|_| AuthError::Serialization)?,
        &Signature::from_bytes(&sig),
    )
    .map_err(|_| AuthError::VerificationFailed)
}

/// True when `expires_at` is at or before `now_epoch`. `expires_at` may be
/// epoch seconds or RFC 3339; an unparseable value counts as expired.
pub fn expiry_passed(expires_at: &str, now_epoch: u64) -> bool {
    if let Ok(seconds) = expires_at.parse::<u64>() {
        return seconds <= now_epoch;
    }
    chrono::DateTime::parse_from_rfc3339(expires_at)
        .map(|when| when.timestamp() <= now_epoch as i64)
        .unwrap_or(true)
}

fn ticket_unsigned(ticket: &CapabilityTicket) -> serde_json::Value {
    let mut value = serde_json::json!({"issuer":ticket.issuer,"subject":ticket.subject,"conversation":ticket.conversation,"capabilities":ticket.capabilities,"expires_at":ticket.expires_at,"ticket_id":ticket.ticket_id});
    if let Some(scope) = &ticket.path_scope {
        if let Some(object) = value.as_object_mut() {
            object.insert(
                "path_scope".into(),
                serde_json::Value::String(scope.clone()),
            );
        }
    }
    // Only present when set, so legacy tickets (voice = None) keep verifying:
    // the signed bytes must stay byte-identical to what the old code signed.
    if let Some(voice) = &ticket.voice {
        if let Some(object) = value.as_object_mut() {
            object.insert(
                "voice".into(),
                serde_json::to_value(voice).expect("voice route serializes"),
            );
        }
    }
    value
}

pub fn sign_state_sync(
    key: &SigningKey,
    account_id: String,
    batch_id: String,
    events: Vec<idfon_protocol::Event>,
) -> idfon_protocol::StateSyncEnvelope {
    let mut envelope = idfon_protocol::StateSyncEnvelope {
        account_id,
        batch_id,
        events,
        signature: String::new(),
    };
    envelope.signature = encode_hex(&key.sign(&state_sync_bytes(&envelope)).to_bytes());
    envelope
}

pub fn verify_state_sync(envelope: &idfon_protocol::StateSyncEnvelope) -> Result<(), AuthError> {
    let public = decode_fixed::<32>(&envelope.account_id).ok_or(AuthError::InvalidPeerId)?;
    let key = VerifyingKey::from_bytes(&public).map_err(|_| AuthError::InvalidPeerId)?;
    let signature = decode_fixed::<64>(&envelope.signature)
        .ok_or(AuthError::InvalidSignature)
        .and_then(|bytes| {
            Signature::from_bytes(&bytes)
                .try_into()
                .map_err(|_| AuthError::InvalidSignature)
        })?;
    key.verify(&state_sync_bytes(envelope), &signature)
        .map_err(|_| AuthError::VerificationFailed)
}

fn state_sync_bytes(envelope: &idfon_protocol::StateSyncEnvelope) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "account_id": envelope.account_id,
        "batch_id": envelope.batch_id,
        "events": envelope.events,
    }))
    .expect("state sync serialization")
}

pub fn verify_message(message: &MessageEnvelope) -> Result<(), AuthError> {
    let public = decode_fixed::<32>(&message.sender.peer_id).ok_or(AuthError::InvalidPeerId)?;
    let verifying_key = VerifyingKey::from_bytes(&public).map_err(|_| AuthError::InvalidPeerId)?;
    let signature = decode_fixed::<64>(&message.sender.signature)
        .ok_or(AuthError::InvalidSignature)
        .and_then(|bytes| {
            Signature::from_bytes(&bytes)
                .try_into()
                .map_err(|_| AuthError::InvalidSignature)
        })?;
    verifying_key
        .verify(&auth_bytes(message)?, &signature)
        .map_err(|_| AuthError::VerificationFailed)
}

#[derive(Serialize)]
struct AuthPayload<'a> {
    message_id: &'a str,
    peer_id: &'a str,
    endpoint_id: &'a str,
    content: &'a MessageContent,
    idempotency_key: &'a str,
    capability_ticket: &'a Option<idfon_protocol::CapabilityTicket>,
    conversation: &'a Option<String>,
}

fn auth_bytes(message: &MessageEnvelope) -> Result<Vec<u8>, AuthError> {
    serde_json::to_vec(&AuthPayload {
        message_id: &message.message_id,
        peer_id: &message.sender.peer_id,
        endpoint_id: &message.sender.endpoint_id,
        content: &message.content,
        idempotency_key: &message.idempotency_key,
        capability_ticket: &message.capability_ticket,
        conversation: &message.conversation,
    })
    .map_err(|_| AuthError::Serialization)
}

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0xf) as usize] as char);
    }
    output
}

fn decode_fixed<const N: usize>(value: &str) -> Option<[u8; N]> {
    if value.len() != N * 2 {
        return None;
    }
    let mut bytes = [0; N];
    for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        bytes[index] = (hex_digit(pair[0])? << 4) | hex_digit(pair[1])?;
    }
    Some(bytes)
}

fn hex_digit(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idfon_protocol::VoiceMode;

    #[test]
    fn endpoint_ref_round_trips_hex_and_z32() {
        let key = generate_identity();
        let id: iroh::EndpointId = peer_id(&key).parse().unwrap();
        let hex = id.to_string();
        assert_eq!(hex.len(), 64);
        assert_eq!(parse_endpoint_ref(&hex), Some(id));

        let short = endpoint_ref(&id);
        assert_eq!(short.len(), 52, "z-base-32 of a 32-byte id is 52 chars");
        assert!(short.len() < 63, "must fit a DNS label");
        assert_eq!(parse_endpoint_ref(&short), Some(id));
        // DNS is case-insensitive; z-base-32 decoding is not.
        assert_eq!(parse_endpoint_ref(&short.to_uppercase()), Some(id));
        assert_eq!(parse_endpoint_ref("not-a-ref"), None);
    }

    #[test]
    fn signed_message_verifies_and_tampering_fails() {
        let key = generate_identity();
        let mut message = sign_message(
            &key,
            "endpoint-a",
            "msg-1",
            MessageContent::Text {
                text: "hello".into(),
            },
            "retry-1",
            None,
        )
        .unwrap();
        assert_eq!(verify_message(&message), Ok(()));
        message.content = MessageContent::Text {
            text: "tampered".into(),
        };
        assert_eq!(verify_message(&message), Err(AuthError::VerificationFailed));
    }

    #[test]
    fn capability_ticket_verifies_and_tampering_fails() {
        let key = generate_identity();
        let mut ticket = issue_capability_ticket(
            &key,
            Some("subject".into()),
            vec![Capability::MessageReceive],
            Some("2099-01-01T00:00:00Z".into()),
            "ticket-1",
        );
        assert_eq!(verify_capability_ticket(&ticket), Ok(()));
        ticket.ticket_id = "ticket-2".into();
        assert_eq!(
            verify_capability_ticket(&ticket),
            Err(AuthError::VerificationFailed)
        );
    }

    #[test]
    fn expiry_accepts_epoch_and_rfc3339() {
        assert!(expiry_passed("1", 100));
        assert!(!expiry_passed("200", 100));
        assert!(expiry_passed("1970-01-01T00:00:01Z", 100));
        assert!(!expiry_passed("2099-01-01T00:00:00Z", 100));
        // Unparseable is treated as expired.
        assert!(expiry_passed("soon", 100));
    }

    #[test]
    fn state_sync_signature_covers_batch_and_events() {
        let key = generate_identity();
        let event = idfon_protocol::Event {
            event_id: "event-1".into(),
            cursor: "cursor-1".into(),
            r#type: "peer.created".into(),
            timestamp: "1".into(),
            identity: "default".into(),
            data: serde_json::json!({"peer_id": "alice"}),
        };
        let mut envelope = sign_state_sync(&key, peer_id(&key), "batch-1".into(), vec![event]);
        assert_eq!(verify_state_sync(&envelope), Ok(()));
        envelope.batch_id = "batch-2".into();
        assert_eq!(
            verify_state_sync(&envelope),
            Err(AuthError::VerificationFailed)
        );
    }

    #[test]
    fn voice_route_is_signed_and_legacy_tickets_still_verify() {
        let key = generate_identity();
        let voice = VoiceRoute {
            mode: VoiceMode::NativeDuplex,
            audio: Some("pcm24k".into()),
            model: Some("openai/gpt-live-1".into()),
            delegate: None,
            stt: None,
            tts: None,
        };
        let ticket = issue_capability_ticket_with_voice(
            &key,
            Some("subject".into()),
            None,
            vec![Capability::MessageReceive],
            None,
            "t-voice",
            Some(voice.clone()),
            None,
        );
        assert!(verify_capability_ticket(&ticket).is_ok());
        assert_eq!(
            serde_json::to_value(&ticket).unwrap()["voice"]["mode"],
            "native-duplex"
        );

        // Routing metadata is signed; tampering fails verification.
        let mut tampered = ticket.clone();
        tampered.voice.as_mut().unwrap().mode = VoiceMode::ClientCascade;
        assert_eq!(
            verify_capability_ticket(&tampered),
            Err(AuthError::VerificationFailed)
        );

        // A legacy ticket (no voice) still verifies: its unsigned payload is
        // byte-identical to what the old issuer signed.
        let legacy = issue_capability_ticket(
            &key,
            Some("subject".into()),
            vec![Capability::MessageReceive],
            None,
            "t-legacy",
        );
        assert!(verify_capability_ticket(&legacy).is_ok());
        assert!(serde_json::to_value(&legacy)
            .unwrap()
            .get("voice")
            .is_none());
    }

    #[test]
    fn malformed_capability_ticket_is_rejected() {
        let mut ticket = CapabilityTicket {
            issuer: "not-a-peer-id".into(),
            subject: None,
            conversation: None,
            path_scope: None,
            capabilities: vec![Capability::MessageReceive],
            expires_at: None,
            ticket_id: "ticket-1".into(),
            voice: None,
            signature: "bad".into(),
        };
        assert_eq!(
            verify_capability_ticket(&ticket),
            Err(AuthError::InvalidPeerId)
        );
        ticket.issuer = "00".repeat(32);
        assert_eq!(
            verify_capability_ticket(&ticket),
            Err(AuthError::InvalidSignature)
        );
    }

    #[test]
    fn endpoint_binding_is_authenticated() {
        let key = generate_identity();
        let mut message = sign_message(
            &key,
            "endpoint-a",
            "msg-1",
            MessageContent::Text {
                text: "hello".into(),
            },
            "retry-1",
            None,
        )
        .unwrap();
        message.sender.endpoint_id = "endpoint-b".into();
        assert_eq!(verify_message(&message), Err(AuthError::VerificationFailed));
    }

    #[test]
    fn trace_is_unsigned_and_does_not_break_verification() {
        let key = generate_identity();
        let mut message = sign_message(
            &key,
            "endpoint-a",
            "msg-trace",
            MessageContent::Text {
                text: "hello".into(),
            },
            "retry-trace",
            None,
        )
        .unwrap();
        assert!(verify_message(&message).is_ok());
        // Attaching or replacing a trace must not invalidate the signature:
        // it is a convenience correlation id, not authenticated content.
        message.trace = Some(new_traceparent());
        assert!(verify_message(&message).is_ok());
        // `telemetry` is likewise an unsigned, best-effort advertisement.
        message.telemetry = Some("inject".into());
        assert!(verify_message(&message).is_ok());
        assert_eq!(new_traceparent().len(), 55);
        assert_ne!(new_traceparent(), new_traceparent());
    }
}
