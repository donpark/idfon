//! Domain security helpers kept independent from transport details.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use nufon_protocol::{Capability, CapabilityTicket, MessageContent, MessageEnvelope, PeerAuth};
use rand_core::OsRng;
use serde::Serialize;
use thiserror::Error;

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
    SigningKey::generate(&mut OsRng)
}

/// Returns the stable hexadecimal public-key identity used as `PeerAuth.peer_id`.
pub fn peer_id(key: &SigningKey) -> String {
    encode_hex(key.verifying_key().as_bytes())
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
    sign_message_with_ticket(key, endpoint_id, message_id, content, idempotency_key, conversation, None)
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

pub fn issue_capability_ticket(key: &SigningKey, subject: Option<String>, capabilities: Vec<Capability>, expires_at: Option<String>, ticket_id: impl Into<String>) -> CapabilityTicket {
    let mut ticket = CapabilityTicket { issuer: peer_id(key), subject, capabilities, expires_at, ticket_id: ticket_id.into(), signature: String::new() };
    ticket.signature = encode_hex(&key.sign(&serde_json::to_vec(&ticket_unsigned(&ticket)).unwrap()).to_bytes());
    ticket
}

pub fn verify_capability_ticket(ticket: &CapabilityTicket) -> Result<(), AuthError> {
    let public = decode_fixed::<32>(&ticket.issuer).ok_or(AuthError::InvalidPeerId)?;
    let key = VerifyingKey::from_bytes(&public).map_err(|_| AuthError::InvalidPeerId)?;
    let sig = decode_fixed::<64>(&ticket.signature).ok_or(AuthError::InvalidSignature)?;
    key.verify(&serde_json::to_vec(&ticket_unsigned(ticket)).map_err(|_| AuthError::Serialization)?, &Signature::from_bytes(&sig)).map_err(|_| AuthError::VerificationFailed)
}

fn ticket_unsigned(ticket: &CapabilityTicket) -> serde_json::Value {
    serde_json::json!({"issuer":ticket.issuer,"subject":ticket.subject,"capabilities":ticket.capabilities,"expires_at":ticket.expires_at,"ticket_id":ticket.ticket_id})
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
    capability_ticket: &'a Option<nufon_protocol::CapabilityTicket>,
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
}
