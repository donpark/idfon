//! Domain security helpers kept independent from transport details.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use getrandom::{rand_core::UnwrapErr, SysRng};
use idfon_protocol::{Capability, MessageContent, MessageEnvelope, PeerAuth, VoiceRoute};
use rcan::{Capability as RcanCapability, Delegation, Expires};
use serde::Serialize;
use thiserror::Error;

pub mod path;
// Gossip + tokio I/O are native-only; the wasm build (Cloudflare Worker) uses
// only the security helpers in this file.
#[cfg(not(target_family = "wasm"))]
pub mod relay;
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
        capability_ticket: capability_ticket.map(|ticket| ticket.token()),
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

/// The signed document inside a capability ticket: everything the issuer
/// vouches for. The `rcan` envelope carries the issuer, the subject (as the
/// audience) and the expiry.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct TicketDoc {
    capabilities: Vec<Capability>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    conversation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    path_scope: Option<String>,
    ticket_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    voice: Option<VoiceRoute>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    relay: Option<String>,
    /// Public/bearer ticket: issued to nobody, presented by anyone. The rcan
    /// audience is then the issuer itself; holders must opt in to admit it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    bearer: bool,
}

impl TicketDoc {
    /// True when this document grants everything `other` asks for. Used by
    /// `rcan` to keep a re-delegation from widening the original grant.
    fn covers(&self, other: &Self) -> bool {
        (self.bearer || !other.bearer)
            && self.ticket_id == other.ticket_id
            && other
                .capabilities
                .iter()
                .all(|wanted| self.capabilities.contains(wanted))
            && (self.conversation.is_none() || self.conversation == other.conversation)
            && (self.relay.is_none() || self.relay == other.relay)
            && match (&self.path_scope, &other.path_scope) {
                (None, _) => true,
                (Some(mine), Some(theirs)) => theirs.starts_with(mine.as_str()),
                (Some(_), None) => false,
            }
    }
}

/// The capability bytes rcan signs and carries: the ticket document as JSON
/// text, verbatim. Nothing canonicalizes or re-encodes it, so the signed bytes
/// and the decoded fields cannot drift apart.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct DocText(String);

impl RcanCapability for DocText {
    fn permits(&self, other: &Self) -> bool {
        match (
            serde_json::from_str::<TicketDoc>(&self.0),
            serde_json::from_str::<TicketDoc>(&other.0),
        ) {
            (Ok(mine), Ok(theirs)) => mine.covers(&theirs),
            _ => false,
        }
    }
}

/// A signed capability ticket: an `rcan` delegation whose capability is the
/// issuer's document. Because the envelope carries issuer, audience and expiry,
/// a holder can re-delegate a narrower copy (`rcan::Delegation::delegate`)
/// without being the issuer.
///
/// There is no way to obtain one that is not signature-checked: mint it, or
/// [`CapabilityTicket::decode`], which verifies as it parses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapabilityTicket {
    delegation: Delegation<DocText>,
    doc: TicketDoc,
}

impl CapabilityTicket {
    fn from_delegation(delegation: Delegation<DocText>) -> Result<Self, AuthError> {
        let doc = serde_json::from_str(delegation.capability().0.as_str())
            .map_err(|_| AuthError::Serialization)?;
        Ok(Self { delegation, doc })
    }

    /// Decodes a ticket token. `rcan` verifies the issuer's signature while
    /// deserializing, so a returned ticket is authentic; the document shape is
    /// validated here.
    pub fn decode(token: &str) -> Result<Self, AuthError> {
        let delegation = Delegation::<DocText>::decode_string(token)
            .map_err(|_| AuthError::VerificationFailed)?;
        Self::from_delegation(delegation)
    }

    /// The wire form: a base32 `rcan` delegation token.
    pub fn token(&self) -> String {
        self.delegation.encode_string()
    }

    /// The issuer's peer id (lowercase hex).
    pub fn issuer(&self) -> String {
        encode_hex(self.delegation.issuer().as_bytes())
    }

    /// The subject endpoint id, or `None` for a public/bearer ticket.
    pub fn subject(&self) -> Option<String> {
        (!self.doc.bearer).then(|| encode_hex(self.delegation.audience().as_bytes()))
    }

    pub fn capabilities(&self) -> &[Capability] {
        &self.doc.capabilities
    }

    pub fn conversation(&self) -> Option<&str> {
        self.doc.conversation.as_deref()
    }

    pub fn path_scope(&self) -> Option<&str> {
        self.doc.path_scope.as_deref()
    }

    pub fn ticket_id(&self) -> &str {
        &self.doc.ticket_id
    }

    pub fn voice(&self) -> Option<&VoiceRoute> {
        self.doc.voice.as_ref()
    }

    pub fn relay(&self) -> Option<&str> {
        self.doc.relay.as_deref()
    }

    pub fn bearer(&self) -> bool {
        self.doc.bearer
    }

    /// Expiry as epoch seconds; `None` = never expires.
    pub fn expires_at(&self) -> Option<u64> {
        match self.delegation.expires() {
            Expires::Never => None,
            Expires::At(seconds) => Some(*seconds),
        }
    }

    pub fn is_expired(&self, now_epoch: u64) -> bool {
        self.expires_at().is_some_and(|seconds| seconds <= now_epoch)
    }

    /// The issuer's ed25519 signature over the delegation, hex.
    pub fn signature_hex(&self) -> String {
        encode_hex(&self.delegation.signature().to_bytes())
    }
}

/// A ticket serializes as its `rcan` token, and only a signature-valid token
/// deserializes, so a decoded ticket is always authentic.
impl Serialize for CapabilityTicket {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.token())
    }
}

impl<'de> serde::Deserialize<'de> for CapabilityTicket {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let token = String::deserialize(deserializer)?;
        CapabilityTicket::decode(&token).map_err(serde::de::Error::custom)
    }
}

/// Mints a ticket. `subject = None` makes it a public/bearer ticket (audience =
/// the issuer, `bearer` set in the signed document).
fn sign_ticket(
    key: &SigningKey,
    subject: Option<String>,
    expires_at: Option<String>,
    mut doc: TicketDoc,
) -> Result<CapabilityTicket, AuthError> {
    doc.bearer = subject.is_none();
    let audience = match subject.as_deref() {
        Some(subject) => decode_fixed::<32>(subject)
            .and_then(|bytes| VerifyingKey::from_bytes(&bytes).ok())
            .ok_or(AuthError::InvalidPeerId)?,
        None => key.verifying_key(),
    };
    let expires = match expires_at.as_deref() {
        Some(value) => Expires::At(expiry_epoch(value).ok_or(AuthError::Serialization)?),
        None => Expires::Never,
    };
    let json = serde_json::to_string(&doc).map_err(|_| AuthError::Serialization)?;
    CapabilityTicket::from_delegation(Delegation::issue(key, audience, &DocText(json), expires))
}

pub fn issue_capability_ticket(
    key: &SigningKey,
    subject: Option<String>,
    capabilities: Vec<Capability>,
    expires_at: Option<String>,
    ticket_id: impl Into<String>,
) -> Result<CapabilityTicket, AuthError> {
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
) -> Result<CapabilityTicket, AuthError> {
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
) -> Result<CapabilityTicket, AuthError> {
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
) -> Result<CapabilityTicket, AuthError> {
    sign_ticket(
        key,
        subject,
        expires_at,
        TicketDoc {
            capabilities,
            conversation,
            path_scope,
            ticket_id: ticket_id.into(),
            voice,
            relay: None,
            bearer: false,
        },
    )
}

/// The signed payload of a relay reachability grant (a "claiming" ticket): the
/// relay URL the issuer vouches for and the revocation id. The `rcan` envelope
/// carries the issuer, the subject endpoint as the audience, and the expiry.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RelayGrant {
    /// Relay URL the issuer claims for the subject's reachability.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay: Option<String>,
    /// Revocation id: the relay cascades a revoke to tokens derived from it.
    pub ticket_id: String,
}

impl RcanCapability for RelayGrant {
    /// A grant permits use of its own relay (or any relay when unbound) under
    /// the same revocation id.
    fn permits(&self, other: &Self) -> bool {
        self.ticket_id == other.ticket_id && (self.relay.is_none() || self.relay == other.relay)
    }
}

/// Mints a relay reachability grant as an `rcan` token: the issuer's identity
/// key binds the **subject** endpoint id (the token's audience) to the issuer's
/// **relay** URL with an expiry. The relay's auth service (`deploy/relay-auth`)
/// admits the subject on the strength of the signature; `Delegation::delegate`
/// lets an admitted caller re-delegate a narrower grant downstream.
pub fn issue_relay_grant(
    key: &SigningKey,
    subject_endpoint_id: impl Into<String>,
    relay_url: impl Into<String>,
    expires_at: Option<String>,
    ticket_id: impl Into<String>,
) -> Result<String, AuthError> {
    let subject = subject_endpoint_id.into();
    let audience = decode_fixed::<32>(&subject)
        .and_then(|bytes| VerifyingKey::from_bytes(&bytes).ok())
        .ok_or(AuthError::InvalidPeerId)?;
    let expires = match expires_at.as_deref() {
        Some(value) => Expires::At(expiry_epoch(value).ok_or(AuthError::Serialization)?),
        None => Expires::Never,
    };
    let grant = RelayGrant {
        relay: Some(relay_url.into()),
        ticket_id: ticket_id.into(),
    };
    Ok(Delegation::issue(key, audience, &grant, expires).encode_string())
}

/// Decodes a relay grant token and verifies its signature. Expiry, issuer trust
/// and revocation are the relay's call (see `docs/relay-auth.md`).
pub fn verify_relay_grant(token: &str) -> Result<RelayGrant, AuthError> {
    let delegation: Delegation<RelayGrant> =
        Delegation::decode_string(token).map_err(|_| AuthError::VerificationFailed)?;
    Ok(delegation.capability())
}

/// The exact bytes an owner-bootstrap proof signs
/// (`deploy/relay-auth/server.mjs` `OWNER_PROOF_PREFIX`). Pinned by the golden
/// vector below and `deploy/relay-auth/test.mjs` — the two sides must agree
/// byte for byte or every enrollment is refused.
pub fn relay_owner_proof_bytes(identity: &str, endpoint: &str, nonce: &str) -> Vec<u8> {
    format!("idfon-relay-owner/1|{identity}|{endpoint}|{nonce}").into_bytes()
}

/// Signs the owner proof with the **identity** key (never the endpoint key:
/// identities created after the account/endpoint split have separate keys).
/// `identity` is the lowercase hex public key, as the relay lists it in
/// `IDFON_RELAY_ISSUERS`.
pub fn sign_relay_owner_proof(
    key: &SigningKey,
    identity: &str,
    endpoint: &str,
    nonce: &str,
) -> String {
    encode_hex(
        &key.sign(&relay_owner_proof_bytes(identity, endpoint, nonce))
            .to_bytes(),
    )
}

/// True when `expires_at` is at or before `now_epoch`. `expires_at` may be
/// epoch seconds or RFC 3339; an unparseable value counts as expired.
pub fn expiry_passed(expires_at: &str, now_epoch: u64) -> bool {
    expiry_epoch(expires_at).is_none_or(|seconds| seconds <= now_epoch)
}

/// Parses an expiry into epoch seconds: plain epoch seconds or RFC 3339.
/// `None` when unparseable (callers treat that as expired).
fn expiry_epoch(value: &str) -> Option<u64> {
    if let Ok(seconds) = value.parse::<u64>() {
        return Some(seconds);
    }
    chrono::DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|when| when.timestamp().max(0) as u64)
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
    capability_ticket: &'a Option<String>,
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
    fn capability_ticket_round_trips_and_tampering_fails() {
        let key = generate_identity();
        let subject = peer_id(&generate_identity());
        let ticket = issue_capability_ticket(
            &key,
            Some(subject.clone()),
            vec![Capability::MessageReceive],
            Some("2099-01-01T00:00:00Z".into()),
            "ticket-1",
        )
        .expect("mints");
        assert_eq!(ticket.issuer(), peer_id(&key));
        assert_eq!(ticket.subject(), Some(subject));
        assert_eq!(ticket.ticket_id(), "ticket-1");
        assert!(!ticket.bearer());
        assert!(!ticket.is_expired(1));

        // The token is the wire form; decoding it reproduces the ticket.
        let token = ticket.token();
        assert_eq!(CapabilityTicket::decode(&token).expect("verifies"), ticket);

        // Flipping a signature character fails closed.
        let mut forged = token.clone();
        let last = forged.pop().expect("non-empty");
        forged.push(if last == 'a' { 'b' } else { 'a' });
        assert_eq!(
            CapabilityTicket::decode(&forged).unwrap_err(),
            AuthError::VerificationFailed
        );

        // Garbage never decodes into a ticket.
        assert!(CapabilityTicket::decode("not-a-token").is_err());
    }

    #[test]
    fn bearer_ticket_has_no_subject_and_still_verifies() {
        let key = generate_identity();
        let ticket = issue_capability_ticket(
            &key,
            None,
            vec![Capability::MessageReceive],
            None,
            "t-public",
        )
        .expect("mints");
        assert!(ticket.bearer());
        assert_eq!(ticket.subject(), None);
        assert_eq!(ticket.expires_at(), None);
        let decoded = CapabilityTicket::decode(&ticket.token()).expect("verifies");
        assert!(decoded.bearer());
        assert_eq!(decoded.subject(), None);
    }

    #[test]
    fn voice_route_is_signed_into_the_ticket() {
        let key = generate_identity();
        let subject = peer_id(&generate_identity());
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
            Some(subject.clone()),
            None,
            vec![Capability::MessageReceive],
            None,
            "t-voice",
            Some(voice.clone()),
            None,
        )
        .expect("mints");
        assert_eq!(ticket.voice(), Some(&voice));
        // A different voice route is a different signed document.
        let plain = issue_capability_ticket_with_voice(
            &key,
            Some(subject),
            None,
            vec![Capability::MessageReceive],
            None,
            "t-voice",
            None,
            None,
        )
        .expect("mints");
        assert_eq!(plain.voice(), None);
        assert_ne!(ticket.token(), plain.token());
    }

    #[test]
    fn a_holder_can_redelegate_but_not_widen() {
        use rcan::Authorizer;

        let owner = generate_identity();
        let holder = generate_identity();
        let caller = generate_identity();
        let ticket = issue_capability_ticket_scoped(
            &owner,
            Some(peer_id(&holder)),
            vec![Capability::MessageReceive, Capability::LiveAudioSubscribe],
            None,
            "t-redelegate",
            Some("/fs".into()),
        )
        .expect("mints");

        let doc = |capabilities: Vec<Capability>, path_scope: &str| TicketDoc {
            capabilities,
            conversation: None,
            path_scope: Some(path_scope.into()),
            ticket_id: "t-redelegate".into(),
            voice: None,
            relay: None,
            bearer: false,
        };
        // The holder re-delegates a narrower slice under the owner's root.
        let narrower = doc(vec![Capability::MessageReceive], "/fs/public");
        let delegated = Delegation::delegate(
            &holder,
            caller.verifying_key(),
            owner.verifying_key(),
            &DocText(serde_json::to_string(&narrower).unwrap()),
            Expires::Never,
        );
        let authorizer = Authorizer::new(owner.verifying_key());
        authorizer
            .check_invocation_from(
                caller.verifying_key(),
                DocText(serde_json::to_string(&narrower).unwrap()),
                &[&ticket.delegation, &delegated],
            )
            .expect("a narrower re-delegation is accepted");

        // A wider path or an extra capability is refused by the chain check.
        for widened in [
            doc(vec![Capability::MessageReceive], "/other"),
            doc(
                vec![Capability::MessageReceive, Capability::McpTransport],
                "/fs/public",
            ),
        ] {
            let bad = Delegation::delegate(
                &holder,
                caller.verifying_key(),
                owner.verifying_key(),
                &DocText(serde_json::to_string(&widened).unwrap()),
                Expires::Never,
            );
            assert!(
                authorizer
                    .check_invocation_from(
                        caller.verifying_key(),
                        DocText(serde_json::to_string(&widened).unwrap()),
                        &[&ticket.delegation, &bad],
                    )
                    .is_err(),
                "widening must not verify"
            );
        }
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
    fn relay_grant_golden_vector() {
        // Cross-language contract: deploy/relay-auth/test.mjs verifies the same
        // token with node:crypto. ed25519 is deterministic, so any drift in the
        // rcan payload encoding breaks one side.
        let key = decode_signing_key(&"07".repeat(32)).expect("fixed key");
        let token = issue_relay_grant(
            &key,
            "11".repeat(32),
            "https://relay.example.com:8443",
            Some("2030-01-01T00:00:00Z".into()),
            "ticket-golden-1",
        )
        .expect("grant mints");
        assert_eq!(token, "alveu3dd4kofecv66vihwezoyx4zkr3wv27l464siipou2iui3jcyeirceirceirceirceirceirceirceirceirceirceirceirceiraaaybmppqydtaai6nb2hi4dthixs64tfnrqxsltfpbqw24dmmuxgg33nhi4dinbtb52gsy3lmv2c2z3pnrsgk3rnghzoj6qqzxlkmpjupwriwbdvgefknpmbgov2ivvzvg3xrbc3z47n6p2urqcex3my2uuyjupmowk5agtgdencpsaatz26drfwkgxfboya");
        let grant = verify_relay_grant(&token).expect("grant verifies");
        assert_eq!(grant.relay.as_deref(), Some("https://relay.example.com:8443"));
        assert_eq!(grant.ticket_id, "ticket-golden-1");
    }

    #[test]
    fn relay_owner_proof_golden_vector() {
        // Cross-language contract with deploy/relay-auth/server.mjs: the
        // owner proof bytes and their ed25519 signature. test.mjs verifies the
        // same vector with node:crypto (verifyEd25519).
        let key = decode_signing_key(&"07".repeat(32)).expect("fixed key");
        let identity = peer_id(&key);
        assert_eq!(identity, "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c");
        let endpoint = "11".repeat(32);
        let nonce = "00112233445566778899aabbccddeeff";
        assert_eq!(
            relay_owner_proof_bytes(&identity, &endpoint, nonce),
            format!("idfon-relay-owner/1|{identity}|{endpoint}|{nonce}").into_bytes()
        );
        assert_eq!(
            sign_relay_owner_proof(&key, &identity, &endpoint, nonce),
            "6024d46a9d40787d532358cd25c704c29684b021f875941c5ebef1f3b3b26fa3e453cb7b9fa1ba75000d89ceda627bf0c3282f7b2eeb61c6574fe3a850a1cf08"
        );
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
