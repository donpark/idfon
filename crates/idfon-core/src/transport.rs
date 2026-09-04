use std::{
    collections::HashMap,
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
};
use tokio::sync::RwLock;

use iroh::{endpoint::presets, Endpoint, EndpointAddr, SecretKey};
use idfon_protocol::{
    decode_frame, encode_frame, AckStatus, MessageAck, MessageEnvelope, MAX_FRAME_BYTES,
};
use thiserror::Error;

pub const MESSAGE_ALPN: &[u8] = b"idfon/message/1";

#[derive(Debug, Error)]
pub enum TransportError {
    #[error("transport failed: {0}")]
    Failed(String),
    #[error("encoded message is too large")]
    MessageTooLarge,
}

pub type SendFuture<'a> =
    Pin<Box<dyn Future<Output = Result<MessageAck, TransportError>> + Send + 'a>>;

pub trait MessageTransport: Send + Sync {
    fn send<'a>(&'a self, target: &'a EndpointAddr, message: &'a MessageEnvelope)
        -> SendFuture<'a>;
}

/// Deterministic transport used by daemon tests. It models successful remote
/// receipt without requiring sockets, discovery, or media dependencies.
#[derive(Clone, Default)]
pub struct FakeTransport {
    sent: Arc<Mutex<Vec<MessageEnvelope>>>,
}

impl FakeTransport {
    pub fn messages(&self) -> Vec<MessageEnvelope> {
        self.sent.lock().expect("fake transport poisoned").clone()
    }
}

impl MessageTransport for FakeTransport {
    fn send<'a>(
        &'a self,
        _target: &'a EndpointAddr,
        message: &'a MessageEnvelope,
    ) -> SendFuture<'a> {
        Box::pin(async move {
            if encode_frame(message)
                .map_err(|_| TransportError::MessageTooLarge)?
                .len()
                > MAX_FRAME_BYTES + 4
            {
                return Err(TransportError::MessageTooLarge);
            }
            self.sent
                .lock()
                .expect("fake transport poisoned")
                .push(message.clone());
            Ok(MessageAck {
                message_id: message.message_id.clone(),
                status: AckStatus::Accepted,
            })
        })
    }
}

/// Real reliable Iroh stream transport. The remote application protocol is
/// responsible for authentication and its delivery acknowledgment.
pub struct IrohTransport {
    endpoint: Endpoint,
    alpn: Vec<u8>,
}

impl IrohTransport {
    pub async fn bind() -> Result<Self, TransportError> {
        Self::bind_with_key(None).await
    }

    pub async fn bind_with_key(key: Option<[u8; 32]>) -> Result<Self, TransportError> {
        let mut builder = Endpoint::builder(presets::N0).alpns(vec![MESSAGE_ALPN.to_vec()]);
        if let Some(key) = key {
            builder = builder.secret_key(SecretKey::from_bytes(&key));
        }
        let endpoint = builder
            .bind()
            .await
            .map_err(|error| TransportError::Failed(error.to_string()))?;
        Ok(Self {
            endpoint,
            alpn: MESSAGE_ALPN.to_vec(),
        })
    }

    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }

    pub async fn shutdown(self) {
        self.endpoint.close().await;
    }

    /// Accepts authenticated message frames and returns application acknowledgments.
    pub async fn serve<F, Fut>(&self, handler: F) -> Result<(), TransportError>
    where
        F: Fn(MessageEnvelope) -> Fut + Clone + Send + Sync + 'static,
        Fut: Future<Output = Result<MessageAck, TransportError>> + Send + 'static,
    {
        loop {
            let incoming = self
                .endpoint
                .accept()
                .await
                .ok_or_else(|| TransportError::Failed("message endpoint closed".into()))?;
            let connection = match incoming.await {
                Ok(connection) => connection,
                Err(error) => {
                    // Expected noise, per iroh's Incoming::accept docs: the QUIC
                    // socket receives unsolicited datagrams that abort handshakes.
                    // Sends retry, so delivery is unaffected.
                    eprintln!("[idfon-core] message connection handshake aborted (background UDP noise): {error}");
                    continue;
                }
            };
            let handler = handler.clone();
            let alpn = self.alpn.clone();
            tokio::spawn(async move {
                let result = async {
                    if connection.alpn() != alpn {
                        return Err(TransportError::Failed("ALPN mismatch".into()));
                    }
                    let (mut send, mut recv) = connection
                        .accept_bi()
                        .await
                        .map_err(|error| TransportError::Failed(error.to_string()))?;
                    let frame = recv
                        .read_to_end(MAX_FRAME_BYTES + 4)
                        .await
                        .map_err(|error| TransportError::Failed(error.to_string()))?;
                    let message: MessageEnvelope = decode_frame(&frame).map_err(|error| {
                        TransportError::Failed(format!("invalid message: {error}"))
                    })?;
                    let ack = handler(message).await?;
                    let ack_frame =
                        encode_frame(&ack).map_err(|_| TransportError::MessageTooLarge)?;
                    send.write_all(&ack_frame)
                        .await
                        .map_err(|error| TransportError::Failed(error.to_string()))?;
                    send.finish()
                        .map_err(|error| TransportError::Failed(error.to_string()))?;
                    connection.closed().await;
                    Ok::<(), TransportError>(())
                }
                .await;
                if let Err(error) = result {
                    eprintln!("message protocol failed: {error}");
                    tracing::warn!("message protocol failed: {error}");
                    connection.close(1u8.into(), b"message rejected");
                }
            });
        }
    }
}

/// Owns the active endpoint and swaps it only after the replacement is bound.
pub struct TransportManager {
    current: RwLock<HashMap<String, Arc<IrohTransport>>>,
}

impl TransportManager {
    pub async fn bind_with_key(key: Option<[u8; 32]>) -> Result<Self, TransportError> {
        let mut transports = HashMap::new();
        transports.insert("default".into(), Arc::new(IrohTransport::bind_with_key(key).await?));
        Ok(Self { current: RwLock::new(transports) })
    }

    pub fn endpoint_id(&self, identity: &str) -> Option<String> {
        self.current.try_read().ok()?.get(identity).map(|transport| transport.endpoint().id().to_string())
    }

    pub fn endpoint_ticket(&self, identity: &str) -> Option<Vec<u8>> {
        serde_json::to_vec(&self.current.try_read().ok()?.get(identity)?.endpoint().addr()).ok()
    }

    pub async fn current(&self, identity: &str) -> Option<Arc<IrohTransport>> {
        self.current.read().await.get(identity).cloned()
    }

    pub async fn add_identity(&self, identity: &str, key: [u8; 32]) -> Result<String, TransportError> {
        let transport = Arc::new(IrohTransport::bind_with_key(Some(key)).await?);
        let endpoint_id = transport.endpoint().id().to_string();
        self.current.write().await.insert(identity.into(), transport);
        Ok(endpoint_id)
    }

    pub async fn serve<F, Fut>(&self, identity: &str, handler: F) -> Result<(), TransportError>
    where
        F: Fn(MessageEnvelope) -> Fut + Clone + Send + Sync + 'static,
        Fut: Future<Output = Result<MessageAck, TransportError>> + Send + 'static,
    {
        loop {
            let current = self.current(identity).await.ok_or_else(|| TransportError::Failed("identity transport not found".into()))?;
            match current.serve(handler.clone()).await {
                Err(TransportError::Failed(message)) if message == "message endpoint closed" => {
                    continue
                }
                result => return result,
            }
        }
    }

    pub async fn rebind(&self, identity: &str, key: Option<[u8; 32]>) -> Result<String, TransportError> {
        let replacement = Arc::new(IrohTransport::bind_with_key(key).await?);
        let id = replacement.endpoint().id().to_string();
        let old = self.current.write().await.insert(identity.into(), replacement);
        if let Some(old) = old { old.endpoint().close().await; }
        Ok(id)
    }

    pub async fn send(&self, identity: &str, target: &EndpointAddr, message: &MessageEnvelope) -> Result<MessageAck, TransportError> {
        self.current(identity).await.ok_or_else(|| TransportError::Failed("identity transport not found".into()))?.send(target, message).await
    }
}

impl MessageTransport for IrohTransport {
    fn send<'a>(
        &'a self,
        target: &'a EndpointAddr,
        message: &'a MessageEnvelope,
    ) -> SendFuture<'a> {
        Box::pin(async move {
            let frame = encode_frame(message).map_err(|_| TransportError::MessageTooLarge)?;
            let connection = self
                .endpoint
                .connect(target.clone(), &self.alpn)
                .await
                .map_err(|error| TransportError::Failed(error.to_string()))?;
            let (mut send, mut recv) = connection
                .open_bi()
                .await
                .map_err(|error| TransportError::Failed(error.to_string()))?;
            send.write_all(&frame)
                .await
                .map_err(|error| TransportError::Failed(error.to_string()))?;
            send.finish()
                .map_err(|error| TransportError::Failed(error.to_string()))?;
            let ack_frame = tokio::time::timeout(
                std::time::Duration::from_secs(30),
                recv.read_to_end(MAX_FRAME_BYTES),
            )
            .await
            .map_err(|_| TransportError::Failed("ack timeout".into()))?
            .map_err(|error| TransportError::Failed(error.to_string()))?;
            let ack: MessageAck = decode_frame(&ack_frame).map_err(|error| {
                TransportError::Failed(format!("invalid acknowledgment: {error}"))
            })?;
            if ack.message_id != message.message_id {
                return Err(TransportError::Failed(
                    "acknowledgment message ID mismatch".into(),
                ));
            }
            connection.close(0u8.into(), b"message sent");
            Ok(ack)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idfon_protocol::{MessageContent, PeerAuth};

    #[test]
    fn transport_manager_rebinds_to_a_new_endpoint() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let manager = TransportManager::bind_with_key(Some([1; 32]))
                .await
                .unwrap();
            let first = manager.endpoint_id("default").unwrap();
            let second = manager.rebind("default", Some([2; 32])).await.unwrap();
            assert_ne!(first, second);
            manager.rebind("default", Some([1; 32])).await.unwrap();
        });
    }

    #[test]
    fn iroh_transport_round_trips_a_message_ack() {
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let receiver = IrohTransport::bind().await.unwrap();
            let sender = IrohTransport::bind().await.unwrap();
            let receiver = std::sync::Arc::new(receiver);
            receiver.endpoint().online().await;
            sender.endpoint().online().await;
            let task_receiver = std::sync::Arc::clone(&receiver);
            let task = tokio::spawn(async move {
                task_receiver
                    .serve(|message| async move {
                        Ok(MessageAck {
                            message_id: message.message_id,
                            status: AckStatus::Accepted,
                        })
                    })
                    .await
            });
            let message = MessageEnvelope {
                message_id: "msg-iroh".into(),
                sender: PeerAuth {
                    peer_id: "peer".into(),
                    endpoint_id: "endpoint".into(),
                    signature: "sig".into(),
                },
                content: MessageContent::Text {
                    text: "hello".into(),
                },
                idempotency_key: "key-iroh".into(),
                capability_ticket: None,
                conversation: None,
            };
            let ack = sender
                .send(&receiver.endpoint().addr(), &message)
                .await
                .unwrap();
            assert_eq!(ack.message_id, message.message_id);
            assert_eq!(ack.status, AckStatus::Accepted);
            task.abort();
            let _ = task.await;
            sender.endpoint().close().await;
            receiver.endpoint().close().await;
        });
    }

    #[test]
    fn fake_transport_records_authenticated_messages() {
        let transport = FakeTransport::default();
        let message = MessageEnvelope {
            message_id: "msg-1".into(),
            sender: PeerAuth {
                peer_id: "peer".into(),
                endpoint_id: "endpoint".into(),
                signature: "sig".into(),
            },
            content: MessageContent::Text {
                text: "hello".into(),
            },
            idempotency_key: "key-1".into(),
            capability_ticket: None,
            conversation: None,
        };
        let target = EndpointAddr::from_parts(
            "0000000000000000000000000000000000000000000000000000000000000000"
                .parse()
                .unwrap(),
            vec![],
        );
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(transport.send(&target, &message))
            .unwrap();
        assert_eq!(transport.messages(), vec![message]);
    }
}
