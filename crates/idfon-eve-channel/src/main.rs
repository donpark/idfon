use std::{
    collections::HashMap,
    io::ErrorKind,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Utc};
use clap::{Parser, Subcommand};
use ed25519_dalek::SigningKey;
use idfon_core::transport::{IrohTransport, MessageTransport, TransportError};
use idfon_core::{peer_id, sign_message, verify_capability_ticket, verify_message, AuthError};
use idfon_protocol::{
    AckStatus, Capability, MessageAck, MessageContent, MessageEnvelope, MAX_FRAME_BYTES,
};
use iroh::{EndpointAddr, EndpointId};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::UnixListener,
    sync::{mpsc, Mutex},
};

const IPC_MAX_FRAME_BYTES: usize = MAX_FRAME_BYTES;
static NEXT_REPLY_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Parser)]
#[command(
    name = "idfon-eve-channel",
    about = "idfon ingress channel endpoint holder"
)]
struct Cli {
    /// Hex Ed25519 key file. `IDFON_EVE_CHANNEL_KEY` is used if unset.
    #[arg(long, global = true, value_name = "FILE")]
    key_file: Option<PathBuf>,
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
        /// Permit an ephemeral identity when no key file or environment key exists.
        #[arg(long)]
        ephemeral: bool,
    },
    /// Issue a holder-signed message.receive ticket for initial provisioning.
    Ticket {
        #[arg(long, value_name = "PEER_ID")]
        subject: String,
        #[arg(long)]
        expires_at: Option<String>,
        #[arg(long)]
        ticket_id: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
enum IpcFrame {
    #[serde(rename = "turn.in")]
    TurnIn {
        message_id: String,
        peer_id: String,
        endpoint_id: String,
        idempotency_key: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation: Option<String>,
        text: String,
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
    #[serde(rename = "error")]
    Error { code: String, message: String },
}

#[derive(Debug, Clone)]
struct ReplyTarget {
    peer_id: String,
    endpoint_id: String,
    conversation: Option<String>,
}

type Targets = Arc<Mutex<HashMap<String, ReplyTarget>>>;
type Seen = Arc<Mutex<HashMap<(String, String), String>>>;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let key_file = cli.key_file;
    match cli.mode {
        Mode::Serve {
            socket,
            allow,
            ephemeral,
        } => {
            let key = load_key(key_file.as_deref(), ephemeral)?;
            serve(socket, allow, key).await
        }
        Mode::Ticket {
            subject,
            expires_at,
            ticket_id,
        } => {
            let key = load_key(key_file.as_deref(), false)?;
            let ticket_id = ticket_id.unwrap_or_else(|| format!("eve-ticket-{}", now_seconds()));
            println!(
                "{}",
                serde_json::to_string(&idfon_core::issue_capability_ticket(
                    &key,
                    Some(subject),
                    vec![Capability::MessageReceive],
                    expires_at,
                    ticket_id,
                ))?
            );
            Ok(())
        }
    }
}

fn load_key(path: Option<&Path>, ephemeral: bool) -> Result<SigningKey> {
    let value = match path {
        Some(path) => Some(
            std::fs::read_to_string(path)
                .with_context(|| format!("read key file {}", path.display()))?,
        ),
        None => std::env::var("IDFON_EVE_CHANNEL_KEY").ok(),
    };
    match value.filter(|value| !value.trim().is_empty()) {
        Some(value) => idfon_core::decode_signing_key(value.trim())
            .ok_or_else(|| anyhow!("invalid key: expected 64 hex characters")),
        None if ephemeral => {
            eprintln!("[idfon-eve-channel] WARNING: no stable key; using an ephemeral identity");
            Ok(idfon_core::generate_identity())
        }
        None => Err(anyhow!(
            "no key configured; pass --key-file, IDFON_EVE_CHANNEL_KEY, or --ephemeral"
        )),
    }
}

async fn serve(socket: PathBuf, allow: Vec<String>, key: SigningKey) -> Result<()> {
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
    let _ = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        transport.endpoint().online(),
    )
    .await;
    println!(
        "{}",
        serde_json::to_string(&transport.endpoint().addr()).context("serialize endpoint ticket")?
    );
    eprintln!(
        "[idfon-eve-channel] serving as {}",
        transport.endpoint().id()
    );

    let (stream, _) = listener.accept().await.context("accept IPC client")?;
    let (reader, writer) = stream.into_split();
    let (out_tx, out_rx) = mpsc::channel(64);
    tokio::spawn(write_frames(writer, out_rx));
    let (reply_tx, mut reply_rx) = mpsc::channel(64);
    tokio::spawn(read_frames(reader, reply_tx));

    let targets = Targets::default();
    let seen = Seen::default();
    let holder_peer_id = peer_id(&key);
    let transport_task = {
        let transport = Arc::clone(&transport);
        let targets = Arc::clone(&targets);
        let seen = Arc::clone(&seen);
        let out_tx = out_tx.clone();
        let allow = Arc::new(allow);
        let holder_peer_id = holder_peer_id.clone();
        tokio::spawn(async move {
            transport
                .serve_with_peer(move |message, remote_id| {
                    handle_message(
                        message,
                        remote_id.to_string(),
                        Arc::clone(&targets),
                        Arc::clone(&seen),
                        out_tx.clone(),
                        allow.clone(),
                        holder_peer_id.clone(),
                    )
                })
                .await
        })
    };

    while let Some(frame) = reply_rx.recv().await {
        if let Err(error) = handle_reply(frame, &key, &transport, &targets, out_tx.clone()).await {
            let _ = out_tx
                .send(IpcFrame::Error {
                    code: "reply_failed".into(),
                    message: error.to_string(),
                })
                .await;
        }
    }

    transport_task.abort();
    let _ = transport_task.await;
    Ok(())
}

async fn handle_message(
    message: MessageEnvelope,
    remote_endpoint_id: String,
    targets: Targets,
    seen: Seen,
    out_tx: mpsc::Sender<IpcFrame>,
    allow: Arc<Vec<String>>,
    holder_peer_id: String,
) -> std::result::Result<MessageAck, TransportError> {
    if let Err(error) = validate_message(&message, &remote_endpoint_id, &allow, &holder_peer_id) {
        eprintln!(
            "[idfon-eve-channel] rejected message={} sender={} signed_endpoint={} remote_endpoint={} ticket_issuer={:?} ticket_subject={:?}: {error}",
            message.message_id,
            message.sender.peer_id,
            message.sender.endpoint_id,
            remote_endpoint_id,
            message.capability_ticket.as_ref().map(|ticket| ticket.issuer.as_str()),
            message.capability_ticket.as_ref().and_then(|ticket| ticket.subject.as_deref()),
        );
        let _ = out_tx
            .send(IpcFrame::Error {
                code: error.code().into(),
                message: error.to_string(),
            })
            .await;
        return Err(TransportError::Failed(error.to_string()));
    }
    let text = match &message.content {
        MessageContent::Text { text } => text.clone(),
    };
    let key = (
        message.sender.peer_id.clone(),
        message.idempotency_key.clone(),
    );
    {
        let mut seen_guard = seen.lock().await;
        if let Some(existing) = seen_guard.get(&key) {
            if existing != &text {
                let error = HolderError::IdempotencyConflict;
                let _ = out_tx
                    .send(IpcFrame::Error {
                        code: error.code().into(),
                        message: error.to_string(),
                    })
                    .await;
                return Err(TransportError::Failed(error.to_string()));
            }
            return Ok(MessageAck {
                message_id: message.message_id,
                status: AckStatus::Duplicate,
            });
        }
        seen_guard.insert(key, text.clone());
    }

    targets.lock().await.insert(
        message.message_id.clone(),
        ReplyTarget {
            peer_id: message.sender.peer_id.clone(),
            endpoint_id: remote_endpoint_id.clone(),
            conversation: message.conversation.clone(),
        },
    );
    out_tx
        .send(IpcFrame::TurnIn {
            message_id: message.message_id.clone(),
            peer_id: message.sender.peer_id.clone(),
            endpoint_id: remote_endpoint_id,
            idempotency_key: message.idempotency_key.clone(),
            conversation: message.conversation.clone(),
            text,
        })
        .await
        .map_err(|_| TransportError::Failed("IPC client disconnected".into()))?;
    Ok(MessageAck {
        message_id: message.message_id,
        status: AckStatus::Accepted,
    })
}

async fn handle_reply(
    frame: IpcFrame,
    key: &SigningKey,
    transport: &IrohTransport,
    targets: &Targets,
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
    let target = targets
        .lock()
        .await
        .get(&in_reply_to)
        .cloned()
        .ok_or_else(|| anyhow!("unknown in_reply_to {}", in_reply_to))?;
    let endpoint_id: EndpointId = target
        .endpoint_id
        .parse()
        .map_err(|error| anyhow!("invalid target endpoint ID: {error}"))?;
    let target_addr = EndpointAddr::new(endpoint_id);
    let message_id = format!(
        "eve_reply_{}",
        NEXT_REPLY_ID.fetch_add(1, Ordering::Relaxed)
    );
    let envelope = sign_message(
        key,
        peer_id(key),
        message_id.clone(),
        MessageContent::Text { text },
        idempotency_key.unwrap_or_else(|| format!("eve-reply-{in_reply_to}")),
        target.conversation,
    )
    .map_err(|error| anyhow!("sign reply: {error}"))?;
    let ack = transport
        .send(&target_addr, &envelope)
        .await
        .map_err(|error| anyhow!("send reply to {}: {error}", target.peer_id))?;
    out_tx
        .send(IpcFrame::ReplyAck {
            in_reply_to,
            message_id,
            status: format!("{:?}", ack.status).to_lowercase(),
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
    IdempotencyConflict,
}

impl HolderError {
    fn code(&self) -> &'static str {
        match self {
            Self::Auth(_) => "unauthorized",
            Self::CapabilityDenied | Self::ExpiredTicket => "capability_denied",
            Self::Unauthorized => "unauthorized",
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
            Self::IdempotencyConflict => {
                write!(f, "idempotency key was reused with different content")
            }
        }
    }
}

impl std::error::Error for HolderError {}

fn validate_message(
    message: &MessageEnvelope,
    remote_endpoint_id: &str,
    allow: &[String],
    holder_peer_id: &str,
) -> std::result::Result<(), HolderError> {
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
    Ok(())
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
                eprintln!("[idfon-eve-channel] IPC read failed: {error}");
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
            eprintln!("[idfon-eve-channel] IPC write failed: {error}");
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
    async fn ipc_frame_round_trips_with_little_endian_length() {
        let frame = IpcFrame::TurnIn {
            message_id: "msg-1".into(),
            peer_id: "peer".into(),
            endpoint_id: "endpoint".into(),
            idempotency_key: "key".into(),
            conversation: Some("thread".into()),
            text: "hello".into(),
        };
        let (mut writer, mut reader) = duplex(4096);
        write_frame(&mut writer, &frame).await.unwrap();
        drop(writer);
        assert!(
            matches!(read_frame(&mut reader).await.unwrap(), Some(IpcFrame::TurnIn { text, .. }) if text == "hello")
        );
    }
}
