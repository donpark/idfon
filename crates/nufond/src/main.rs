#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::{
    io,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use nufon_core::transport::{FakeTransport, IrohTransport, MessageTransport};
use nufon_protocol::{
    encode_json, validate_request, ApiError, ErrorCode, Identity, Request, Response, ResponseBody,
    PROTOCOL_VERSION,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
};

const DEFAULT_SOCKET: &str = "/tmp/nufon/nufond.sock";
const DEFAULT_DATA_DIR: &str = "/tmp/nufon";
const DEFAULT_TRANSPORT: &str = "iroh";

enum TransportMode {
    Fake(FakeTransport),
    Iroh(Arc<IrohTransport>),
}

impl TransportMode {
    async fn new(name: &str, key: Option<[u8; 32]>) -> io::Result<Self> {
        match name {
            "fake" => Ok(Self::Fake(FakeTransport::default())),
            "iroh" => IrohTransport::bind_with_key(key)
                .await
                .map(Arc::new)
                .map(Self::Iroh)
                .map_err(io::Error::other),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "transport must be fake or iroh",
            )),
        }
    }

    fn endpoint_id(&self) -> Option<String> {
        match self {
            Self::Fake(_) => None,
            Self::Iroh(transport) => Some(transport.endpoint().id().to_string()),
        }
    }

    fn send(
        &self,
        peer: &nufon_protocol::Peer,
        message: &nufon_protocol::MessageEnvelope,
    ) -> io::Result<nufon_protocol::MessageAck> {
        let address = if matches!(self, Self::Fake(_)) {
            "0000000000000000000000000000000000000000000000000000000000000000"
        } else {
            peer.endpoint_addr.as_deref().ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "peer has no endpoint address")
            })?
        };
        let target = serde_json::from_str(address).map_err(|error| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("invalid endpoint address: {error}"),
            )
        })?;
        std::thread::scope(|scope| {
            scope
                .spawn(|| {
                    let runtime = tokio::runtime::Runtime::new()?;
                    match self {
                        Self::Fake(transport) => runtime.block_on(transport.send(&target, message)),
                        Self::Iroh(transport) => runtime.block_on(transport.send(&target, message)),
                    }
                    .map_err(io::Error::other)
                })
                .join()
                .map_err(|_| io::Error::other("transport worker panicked"))?
        })
    }
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct Store {
    identities: Vec<Identity>,
    peers: Vec<nufon_protocol::Peer>,
    #[serde(default)]
    operations: Vec<nufon_protocol::Operation>,
    #[serde(default)]
    events: Vec<nufon_protocol::Event>,
    #[serde(default)]
    messages: Vec<nufon_protocol::MessageEnvelope>,
    #[serde(default)]
    grants: Vec<nufon_protocol::CapabilityGrant>,
    #[serde(skip)]
    data_dir: PathBuf,
}

impl Store {
    fn load(data_dir: &Path) -> io::Result<Self> {
        let path = data_dir.join("state.json");
        match std::fs::read(&path) {
            Ok(bytes) => {
                let mut store: Self = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
                store.data_dir = data_dir.to_path_buf();
                store.ensure_identity_keys(data_dir)?;
                Ok(store)
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let store = Self {
                    identities: vec![Identity {
                        id: "default".into(),
                        name: "Default".into(),
                        endpoint_id: None,
                        public_key: None,
                        active: true,
                    }],
                    peers: Vec::new(),
                    operations: Vec::new(),
                    events: Vec::new(),
                    messages: Vec::new(),
                    grants: Vec::new(),
                    data_dir: data_dir.to_path_buf(),
                };
                let mut store = store;
                store.ensure_identity_keys(data_dir)?;
                Ok(store)
            }
            Err(error) => Err(error),
        }
    }

    fn ensure_identity_keys(&mut self, data_dir: &Path) -> io::Result<()> {
        std::fs::create_dir_all(data_dir)?;
        for identity in &mut self.identities {
            let path = data_dir.join(format!("identity-{}.key", identity.id));
            let key = match std::fs::read_to_string(&path) {
                Ok(value) => nufon_core::decode_signing_key(value.trim()).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "invalid identity key")
                })?,
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    let key = nufon_core::generate_identity();
                    let value = nufon_core::encode_signing_key(&key);
                    std::fs::write(&path, value)?;
                    #[cfg(unix)]
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
                    key
                }
                Err(error) => return Err(error),
            };
            identity.public_key = Some(nufon_core::peer_id(&key));
        }
        self.save(data_dir)
    }

    fn identity_key(&self, identity_id: &str) -> io::Result<ed25519_dalek::SigningKey> {
        let path = self.data_dir.join(format!("identity-{identity_id}.key"));
        let value = std::fs::read_to_string(path)?;
        nufon_core::decode_signing_key(value.trim())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid identity key"))
    }

    fn save(&self, data_dir: &Path) -> io::Result<()> {
        std::fs::create_dir_all(data_dir)?;
        let bytes = serde_json::to_vec_pretty(self).map_err(io::Error::other)?;
        let temporary = data_dir.join("state.json.tmp");
        std::fs::write(&temporary, bytes)?;
        std::fs::rename(temporary, data_dir.join("state.json"))
    }
}

#[tokio::main]
async fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let socket =
        PathBuf::from(argument(&args, "--socket").unwrap_or_else(|| DEFAULT_SOCKET.into()));
    let data_dir =
        PathBuf::from(argument(&args, "--data-dir").unwrap_or_else(|| DEFAULT_DATA_DIR.into()));
    let transport = argument(&args, "--transport").unwrap_or_else(|| DEFAULT_TRANSPORT.into());
    if transport != "fake" && transport != "iroh" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "--transport must be fake or iroh",
        ));
    }
    let _data_lock = DataLock::acquire(&data_dir)?;
    let store = Arc::new(Mutex::new(Store::load(&data_dir)?));
    let identity_key = store
        .lock()
        .expect("store mutex poisoned")
        .identity_key("default")?;
    let transport = Arc::new(
        TransportMode::new(
            &transport,
            Some(nufon_core::signing_key_bytes(&identity_key)),
        )
        .await?,
    );
    if let Some(endpoint_id) = transport.endpoint_id() {
        let mut state = store.lock().expect("store mutex poisoned");
        if let Some(identity) = state.identities.iter_mut().find(|identity| identity.active) {
            identity.endpoint_id = Some(endpoint_id);
        }
        let data_dir = state.data_dir.clone();
        state.save(&data_dir)?;
    }
    if let TransportMode::Iroh(iroh) = transport.as_ref() {
        let iroh = Arc::clone(iroh);
        let receiver_store = Arc::clone(&store);
        tokio::spawn(async move {
            let result = iroh
                .serve(move |message| {
                    let store = Arc::clone(&receiver_store);
                    async move {
                        let request = Request {
                            version: PROTOCOL_VERSION,
                            id: format!("transport-{}", message.message_id),
                            method: "message.receive".into(),
                            params: serde_json::to_value(message).map_err(|error| {
                                nufon_core::transport::TransportError::Failed(error.to_string())
                            })?,
                        };
                        let response = dispatch(request, &store);
                        match response.body {
                            ResponseBody::Success { result, .. } => {
                                Ok(nufon_protocol::MessageAck {
                                    message_id: result["message_id"]
                                        .as_str()
                                        .unwrap_or_default()
                                        .into(),
                                    status: if result["status"] == "duplicate" {
                                        nufon_protocol::AckStatus::Duplicate
                                    } else {
                                        nufon_protocol::AckStatus::Accepted
                                    },
                                })
                            }
                            ResponseBody::Failure { error, .. } => {
                                Err(nufon_core::transport::TransportError::Failed(error.message))
                            }
                        }
                    }
                })
                .await;
            if let Err(error) = result {
                eprintln!("nufond Iroh receiver stopped: {error}");
            }
        });
    }
    prepare_socket(&socket)?;
    if let Some(parent) = socket.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let listener = UnixListener::bind(&socket)?;
    #[cfg(unix)]
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    let _cleanup = SocketCleanup(socket.clone());

    tokio::select! {
        result = accept_loop(listener, store, transport) => result,
        result = tokio::signal::ctrl_c() => result.map_err(io::Error::other),
    }
}

async fn accept_loop(
    listener: UnixListener,
    store: Arc<Mutex<Store>>,
    transport: Arc<TransportMode>,
) -> io::Result<()> {
    loop {
        let (stream, _) = listener.accept().await?;
        let store = Arc::clone(&store);
        let transport = Arc::clone(&transport);
        tokio::spawn(async move {
            if let Err(error) = serve(stream, store, transport).await {
                eprintln!("nufond client error: {error}");
            }
        });
    }
}

async fn serve(
    mut stream: UnixStream,
    store: Arc<Mutex<Store>>,
    transport: Arc<TransportMode>,
) -> io::Result<()> {
    loop {
        let Some(frame) = read_frame(&mut stream).await? else {
            return Ok(());
        };
        let response = match serde_json::from_slice::<Request>(&frame) {
            Ok(request) => dispatch_with_transport(request, &store, &transport),
            Err(error) => error_response(
                "unknown".into(),
                "protocol",
                ErrorCode::InvalidJson,
                error.to_string(),
                false,
            ),
        };
        write_frame(
            &mut stream,
            &encode_json(&response).map_err(io::Error::other)?,
        )
        .await?;
    }
}

fn dispatch(request: Request, store: &Arc<Mutex<Store>>) -> Response {
    let transport = Arc::new(TransportMode::Fake(FakeTransport::default()));
    dispatch_with_transport(request, store, &transport)
}

fn dispatch_with_transport(
    request: Request,
    store: &Arc<Mutex<Store>>,
    transport: &Arc<TransportMode>,
) -> Response {
    if let Err(error) = validate_request(&request) {
        let (code, message) = match error {
            nufon_protocol::ProtocolError::InvalidVersion(version) => (
                ErrorCode::InvalidVersion,
                format!("unsupported protocol version {version}"),
            ),
            nufon_protocol::ProtocolError::FrameTooLarge => {
                (ErrorCode::FrameTooLarge, "frame is too large".into())
            }
        };
        return error_response(request.id, &request.method, code, message, false);
    }

    match request.method.as_str() {
        "message.receive" => receive_message(&request, store),
        "message.send" => send_message(&request, store, transport),
        "operation.get" => operation_get(&request, store),
        "operation.cancel" => operation_cancel(&request, store),
        "events" => events(&request, store),
        "status" => success(
            &request,
            serde_json::json!({
                "daemon": "nufond",
                "ready": true,
                "protocol_version": PROTOCOL_VERSION,
            }),
        ),
        "context" => {
            let state = store.lock().expect("store mutex poisoned");
            success(
                &request,
                serde_json::json!({
                    "identity": state.identities.iter().find(|identity| identity.active),
                    "daemon": "nufond",
                    "ready": true,
                }),
            )
        }
        "identities" => {
            let state = store.lock().expect("store mutex poisoned");
            success(
                &request,
                serde_json::json!({"identities": state.identities}),
            )
        }
        "peers" => {
            let state = store.lock().expect("store mutex poisoned");
            success(&request, serde_json::json!({"peers": state.peers}))
        }
        "peer.resolve" => {
            let reference = request
                .params
                .get("ref")
                .and_then(serde_json::Value::as_str);
            let state = store.lock().expect("store mutex poisoned");
            let matches: Vec<_> = state
                .peers
                .iter()
                .filter(|peer| {
                    reference.is_some_and(|reference| {
                        peer.id == reference
                            || peer.name == reference
                            || peer.aliases.iter().any(|alias| alias == reference)
                            || peer.endpoint_id.as_deref() == Some(reference)
                    })
                })
                .collect();
            match matches.as_slice() {
                [peer] => success(&request, serde_json::json!({"peer": peer})),
                [] => error_response(
                    request.id,
                    &request.method,
                    ErrorCode::InvalidRequest,
                    "peer not found".into(),
                    false,
                ),
                _ => error_response(
                    request.id,
                    &request.method,
                    ErrorCode::AmbiguousPeer,
                    "peer reference is ambiguous".into(),
                    false,
                ),
            }
        }
        _ => error_response(
            request.id,
            &request.method,
            ErrorCode::UnknownMethod,
            format!("unknown method '{}'", request.method),
            false,
        ),
    }
}

fn send_message(
    request: &Request,
    store: &Arc<Mutex<Store>>,
    transport: &Arc<TransportMode>,
) -> Response {
    let to = request.params.get("to").and_then(serde_json::Value::as_str);
    let text = request
        .params
        .get("text")
        .and_then(serde_json::Value::as_str);
    let key = request
        .params
        .get("idempotency_key")
        .and_then(serde_json::Value::as_str);
    let retries = request
        .params
        .get("retries")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0)
        .min(3) as usize;
    if to.is_none()
        || text.is_none()
        || key.is_none()
        || text.is_some_and(str::is_empty)
        || key.is_some_and(str::is_empty)
    {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "to, text, and idempotency_key are required".into(),
            false,
        );
    }
    let to = to.unwrap();
    let text = text.unwrap();
    let key = key.unwrap();
    let fingerprint = serde_json::to_string(&serde_json::json!({"to": to, "text": text})).unwrap();
    let mut state = store.lock().expect("store mutex poisoned");
    let identity = match state
        .identities
        .iter()
        .find(|identity| identity.active)
        .cloned()
    {
        Some(identity) => identity,
        None => {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::InvalidRequest,
                "no active identity".into(),
                false,
            )
        }
    };
    let peer = match state.peers.iter().find(|peer| {
        peer.id == to || peer.name == to || peer.aliases.iter().any(|alias| alias == to)
    }) {
        Some(peer) => peer.clone(),
        None => {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::InvalidRequest,
                "peer not found".into(),
                false,
            )
        }
    };
    if !state.grants.iter().any(|grant| {
        grant.identity == identity.id
            && grant.subject == peer.id
            && grant.capability == nufon_protocol::Capability::MessageSend
            && grant.revoked_at.is_none()
    }) {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::CapabilityDenied,
            "message.send capability denied".into(),
            false,
        );
    }
    if let Some(existing) = state.operations.iter().find(|operation| {
        operation.target.as_deref() == Some(peer.id.as_str())
            && operation.idempotency_key.as_deref() == Some(key)
    }) {
        if existing.request_fingerprint.as_deref() != Some(fingerprint.as_str()) {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::IdempotencyKeyConflict,
                "idempotency key was reused with different content".into(),
                false,
            );
        }
        return success(
            request,
            serde_json::json!({"operation_id": existing.operation_id, "status": existing.status}),
        );
    }
    let signing_key = match state.identity_key(&identity.id) {
        Ok(key) => key,
        Err(error) => {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::Internal,
                error.to_string(),
                false,
            )
        }
    };
    let message_id = format!("msg_{}", state.operations.len() + 1);
    let envelope = match nufon_core::sign_message(
        &signing_key,
        identity.endpoint_id.unwrap_or_default(),
        message_id.clone(),
        nufon_protocol::MessageContent::Text { text: text.into() },
        key,
        None,
    ) {
        Ok(envelope) => envelope,
        Err(error) => {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::Internal,
                error.to_string(),
                false,
            )
        }
    };
    let timestamp = now();
    let operation = nufon_protocol::Operation {
        operation_id: format!("op_{message_id}"),
        method: request.method.clone(),
        status: nufon_protocol::OperationStatus::Queued,
        target: Some(peer.id.clone()),
        request_fingerprint: Some(fingerprint),
        created_at: timestamp.clone(),
        updated_at: timestamp,
        idempotency_key: Some(key.into()),
        message_id: Some(envelope.message_id.clone()),
    };
    state.operations.push(operation.clone());
    let result = state.save(&state.data_dir);
    drop(state);
    if let Err(error) = result {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::Internal,
            error.to_string(),
            true,
        );
    }
    let operation_id = operation.operation_id.clone();
    let response_message_id = envelope.message_id.clone();
    let worker_store = Arc::clone(store);
    let worker_transport = Arc::clone(transport);
    let worker_envelope = envelope.clone();
    let worker_peer = peer.clone();
    tokio::spawn(async move {
        let transition = tokio::task::spawn_blocking({
            let store = Arc::clone(&worker_store);
            let operation_id = operation_id.clone();
            move || {
                update_operation(
                    &store,
                    &operation_id,
                    nufon_protocol::OperationStatus::Transmitting,
                )
            }
        })
        .await;
        if transition.is_err() || transition.ok().and_then(Result::err).is_some() {
            return;
        }
        let mut delivery = Err(io::Error::other("no transport attempt"));
        for _ in 0..=retries {
            if is_cancelled(&worker_store, &operation_id) {
                let _ = update_operation(
                    &worker_store,
                    &operation_id,
                    nufon_protocol::OperationStatus::Cancelled,
                );
                return;
            }
            let transport = Arc::clone(&worker_transport);
            let peer = worker_peer.clone();
            let envelope = worker_envelope.clone();
            delivery =
                match tokio::task::spawn_blocking(move || transport.send(&peer, &envelope)).await {
                    Ok(result) => result,
                    Err(error) => Err(io::Error::other(error)),
                };
            if delivery.is_ok() {
                break;
            }
        }
        let status = if delivery.is_ok() {
            nufon_protocol::OperationStatus::Delivered
        } else {
            nufon_protocol::OperationStatus::Failed
        };
        let _ = tokio::task::spawn_blocking(move || {
            update_operation(&worker_store, &operation_id, status)
        })
        .await;
    });
    success(
        request,
        serde_json::json!({"operation_id": operation.operation_id, "message_id": response_message_id, "status": "queued", "authenticated": true}),
    )
}

fn is_cancelled(store: &Arc<Mutex<Store>>, operation_id: &str) -> bool {
    store
        .lock()
        .expect("store mutex poisoned")
        .operations
        .iter()
        .any(|operation| {
            operation.operation_id == operation_id
                && operation.status == nufon_protocol::OperationStatus::Cancelled
        })
}

fn operation_cancel(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(id) = request
        .params
        .get("operation_id")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "operation_id is required".into(),
            false,
        );
    };
    let mut state = store.lock().expect("store mutex poisoned");
    let Some(operation) = state
        .operations
        .iter_mut()
        .find(|operation| operation.operation_id == id)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "operation not found".into(),
            false,
        );
    };
    if matches!(
        operation.status,
        nufon_protocol::OperationStatus::Delivered
            | nufon_protocol::OperationStatus::Failed
            | nufon_protocol::OperationStatus::Expired
    ) {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "operation is already terminal".into(),
            false,
        );
    }
    operation.status = nufon_protocol::OperationStatus::Cancelled;
    operation.updated_at = now();
    let data_dir = state.data_dir.clone();
    if let Err(error) = state.save(&data_dir) {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::Internal,
            error.to_string(),
            true,
        );
    }
    success(
        request,
        serde_json::json!({"operation_id": id, "status": "cancelled"}),
    )
}

fn update_operation(
    store: &Arc<Mutex<Store>>,
    operation_id: &str,
    status: nufon_protocol::OperationStatus,
) -> io::Result<()> {
    let mut state = store.lock().expect("store mutex poisoned");
    if let Some(operation) = state
        .operations
        .iter_mut()
        .find(|operation| operation.operation_id == operation_id)
    {
        operation.status = status.clone();
        operation.updated_at = now();
        let event_number = state.events.len() + 1;
        let cursor = format!("cur_{event_number:020}");
        state.events.push(nufon_protocol::Event {
            event_id: format!("evt_{operation_id}_{event_number}"),
            cursor,
            r#type: "operation.state_changed".into(),
            timestamp: now(),
            identity: "default".into(),
            data: serde_json::json!({"operation_id": operation_id, "status": status}),
        });
    }
    let data_dir = state.data_dir.clone();
    state.save(&data_dir)
}

fn receive_message(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let envelope =
        match serde_json::from_value::<nufon_protocol::MessageEnvelope>(request.params.clone()) {
            Ok(envelope) => envelope,
            Err(error) => {
                return error_response(
                    request.id.clone(),
                    &request.method,
                    ErrorCode::InvalidRequest,
                    format!("invalid message envelope: {error}"),
                    false,
                )
            }
        };
    if let Err(error) = nufon_core::verify_message(&envelope) {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::Unauthorized,
            error.to_string(),
            false,
        );
    }
    let state = store.lock().expect("store mutex poisoned");
    let known_peer = state.peers.iter().any(|peer| {
        peer.id == envelope.sender.peer_id
            && peer.endpoint_id.as_deref() == Some(envelope.sender.endpoint_id.as_str())
    });
    let allowed = state.grants.iter().any(|grant| {
        grant.capability == nufon_protocol::Capability::MessageReceive
            && grant.subject == envelope.sender.peer_id
            && grant.revoked_at.is_none()
            && grant
                .expires_at
                .as_deref()
                .is_none_or(|expires| expires > now().as_str())
    });
    drop(state);
    if !known_peer {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::Unauthorized,
            "sender is not a persisted peer".into(),
            false,
        );
    }
    if !allowed {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::CapabilityDenied,
            "sender lacks message.receive capability".into(),
            false,
        );
    }
    let mut state = store.lock().expect("store mutex poisoned");
    if let Some(existing) = state.messages.iter().find(|message| {
        message.sender.peer_id == envelope.sender.peer_id
            && message.idempotency_key == envelope.idempotency_key
    }) {
        if existing.content != envelope.content {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::IdempotencyKeyConflict,
                "idempotency key was reused with different content".into(),
                false,
            );
        }
        return success(
            request,
            serde_json::json!({
                "message_id": existing.message_id,
                "status": "duplicate",
            }),
        );
    }
    let now = now();
    let operation = nufon_protocol::Operation {
        operation_id: format!("op_{}", envelope.message_id),
        method: request.method.clone(),
        status: nufon_protocol::OperationStatus::Delivered,
        target: Some(envelope.sender.peer_id.clone()),
        request_fingerprint: None,
        created_at: now.clone(),
        updated_at: now.clone(),
        idempotency_key: Some(envelope.idempotency_key.clone()),
        message_id: Some(envelope.message_id.clone()),
    };
    state.messages.push(envelope.clone());
    state.operations.push(operation.clone());
    let cursor = format!("cur_{:020}", state.events.len() + 1);
    let identity = state
        .identities
        .iter()
        .find(|identity| identity.active)
        .map(|identity| identity.id.clone())
        .unwrap_or_default();
    state.events.push(nufon_protocol::Event {
        event_id: format!("evt_{}", envelope.message_id),
        cursor,
        r#type: "message.received".into(),
        timestamp: now,
        identity,
        data: serde_json::json!({"message_id": envelope.message_id, "peer_id": envelope.sender.peer_id}),
    });
    let result = state.save(&state.data_dir);
    drop(state);
    if let Err(error) = result {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::Internal,
            error.to_string(),
            true,
        );
    }
    success(
        request,
        serde_json::json!({
            "message_id": operation.message_id,
            "operation_id": operation.operation_id,
            "status": "delivered",
        }),
    )
}

fn operation_get(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let id = request
        .params
        .get("operation_id")
        .and_then(serde_json::Value::as_str);
    let state = store.lock().expect("store mutex poisoned");
    match id.and_then(|id| {
        state
            .operations
            .iter()
            .find(|operation| operation.operation_id == id)
    }) {
        Some(operation) => success(request, serde_json::json!({"operation": operation})),
        None => error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "operation not found".into(),
            false,
        ),
    }
}

fn events(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let after = request
        .params
        .get("after")
        .and_then(serde_json::Value::as_str);
    let state = store.lock().expect("store mutex poisoned");
    let events: Vec<_> = state
        .events
        .iter()
        .filter(|event| after.is_none_or(|cursor| event.cursor.as_str() > cursor))
        .cloned()
        .collect();
    success(request, serde_json::json!({"events": events}))
}

fn now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .to_string()
}

fn success(request: &Request, result: serde_json::Value) -> Response {
    Response {
        version: PROTOCOL_VERSION,
        id: request.id.clone(),
        ok: true,
        body: ResponseBody::Success {
            operation: request.method.clone(),
            result,
        },
    }
}

fn error_response(
    id: String,
    operation: &str,
    code: ErrorCode,
    message: String,
    retryable: bool,
) -> Response {
    Response {
        version: PROTOCOL_VERSION,
        id,
        ok: false,
        body: ResponseBody::Failure {
            operation: operation.into(),
            error: ApiError {
                code,
                message,
                retryable,
                retry_after_ms: None,
                next: Vec::new(),
            },
        },
    }
}

async fn read_frame(stream: &mut UnixStream) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0; 4];
    match stream.read_exact(&mut header).await {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let length = u32::from_be_bytes(header) as usize;
    if length > nufon_protocol::MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    let mut frame = vec![0; length];
    stream.read_exact(&mut frame).await?;
    Ok(Some(frame))
}

async fn write_frame(stream: &mut UnixStream, payload: &[u8]) -> io::Result<()> {
    if payload.len() > nufon_protocol::MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    stream
        .write_all(&(payload.len() as u32).to_be_bytes())
        .await?;
    stream.write_all(payload).await
}

fn argument(args: &[String], name: &str) -> Option<String> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].clone())
}

fn prepare_socket(socket: &Path) -> io::Result<()> {
    if !socket.exists() {
        return Ok(());
    }
    match std::os::unix::net::UnixStream::connect(socket) {
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "another nufond is already using this socket",
        )),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
            ) =>
        {
            if socket.is_file() {
                std::fs::remove_file(socket)
            } else {
                Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "socket path is not a file",
                ))
            }
        }
        Err(error) => Err(error),
    }
}

struct DataLock(PathBuf);

impl DataLock {
    fn acquire(data_dir: &Path) -> io::Result<Self> {
        std::fs::create_dir_all(data_dir)?;
        let path = data_dir.join("state.lock");
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .and_then(|mut file| {
                use std::io::Write;
                writeln!(file, "{}", std::process::id())
            })
            .map_err(|error| {
                if error.kind() == io::ErrorKind::AlreadyExists {
                    io::Error::new(
                        io::ErrorKind::AddrInUse,
                        format!("data directory is already locked: {}", path.display()),
                    )
                } else {
                    error
                }
            })?;
        Ok(Self(path))
    }
}

impl Drop for DataLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

struct SocketCleanup(PathBuf);

impl Drop for SocketCleanup {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "nufond-{name}-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn authenticated_message_is_accepted_and_tampering_rejected() {
        let dir = temp_dir("auth");
        let store = Arc::new(Mutex::new(Store::load(&dir).unwrap()));
        let key = nufon_core::generate_identity();
        let message = nufon_core::sign_message(
            &key,
            "endpoint-a",
            "msg-1",
            nufon_protocol::MessageContent::Text {
                text: "hello".into(),
            },
            "retry-1",
            None,
        )
        .unwrap();
        let peer_id = nufon_core::peer_id(&key);
        let mut state = store.lock().unwrap();
        state.peers.push(nufon_protocol::Peer {
            id: peer_id.clone(),
            name: "Alice".into(),
            endpoint_id: Some("endpoint-a".into()),
            endpoint_addr: None,
            aliases: Vec::new(),
        });
        state.grants.push(nufon_protocol::CapabilityGrant {
            capability: nufon_protocol::Capability::MessageReceive,
            identity: "default".into(),
            subject: peer_id,
            conversation: None,
            active_at: "0".into(),
            expires_at: None,
            revision: 1,
            revoked_at: None,
        });
        drop(state);
        let request = Request {
            version: PROTOCOL_VERSION,
            id: "test".into(),
            method: "message.receive".into(),
            params: serde_json::to_value(&message).unwrap(),
        };
        assert!(dispatch(request.clone(), &store).ok);

        let mut tampered = message;
        tampered.content = nufon_protocol::MessageContent::Text {
            text: "changed".into(),
        };
        let response = dispatch(
            Request {
                params: serde_json::to_value(tampered).unwrap(),
                ..request
            },
            &store,
        );
        assert!(matches!(
            response.body,
            ResponseBody::Failure {
                error: ApiError {
                    code: ErrorCode::Unauthorized,
                    ..
                },
                ..
            }
        ));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn duplicate_message_is_idempotent_and_conflicting_retry_is_rejected() {
        let dir = temp_dir("idempotency");
        let store = Arc::new(Mutex::new(Store::load(&dir).unwrap()));
        let key = nufon_core::generate_identity();
        let peer_id = nufon_core::peer_id(&key);
        let mut state = store.lock().unwrap();
        state.peers.push(nufon_protocol::Peer {
            id: peer_id.clone(),
            name: "Alice".into(),
            endpoint_id: Some("ep".into()),
            endpoint_addr: None,
            aliases: vec![],
        });
        state.grants.push(nufon_protocol::CapabilityGrant {
            capability: nufon_protocol::Capability::MessageReceive,
            identity: "default".into(),
            subject: peer_id.clone(),
            conversation: None,
            active_at: "0".into(),
            expires_at: None,
            revision: 1,
            revoked_at: None,
        });
        drop(state);
        let signed = |text: &str| {
            nufon_core::sign_message(
                &key,
                "ep",
                "msg-1",
                nufon_protocol::MessageContent::Text { text: text.into() },
                "key-1",
                None,
            )
            .unwrap()
        };
        let request = |message| Request {
            version: PROTOCOL_VERSION,
            id: "test".into(),
            method: "message.receive".into(),
            params: serde_json::to_value(message).unwrap(),
        };
        assert!(dispatch(request(signed("hello")), &store).ok);
        let duplicate = dispatch(request(signed("hello")), &store);
        assert!(duplicate.ok);
        let conflict = dispatch(request(signed("changed")), &store);
        assert!(matches!(
            conflict.body,
            ResponseBody::Failure {
                error: ApiError {
                    code: ErrorCode::IdempotencyKeyConflict,
                    ..
                },
                ..
            }
        ));
        let reloaded = Store::load(&dir).unwrap();
        assert_eq!(reloaded.messages.len(), 1);
        assert_eq!(reloaded.events.len(), 1);
        assert_eq!(reloaded.operations.len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn operation_cancel_marks_queued_work_cancelled() {
        let dir = temp_dir("cancel");
        let store = Arc::new(Mutex::new(Store::load(&dir).unwrap()));
        store
            .lock()
            .unwrap()
            .operations
            .push(nufon_protocol::Operation {
                operation_id: "op_cancel".into(),
                method: "message.send".into(),
                status: nufon_protocol::OperationStatus::Queued,
                target: None,
                request_fingerprint: None,
                created_at: now(),
                updated_at: now(),
                idempotency_key: Some("key".into()),
                message_id: Some("msg".into()),
            });
        let response = dispatch(
            Request {
                version: PROTOCOL_VERSION,
                id: "test".into(),
                method: "operation.cancel".into(),
                params: serde_json::json!({"operation_id": "op_cancel"}),
            },
            &store,
        );
        assert!(response.ok);
        assert_eq!(
            store.lock().unwrap().operations[0].status,
            nufon_protocol::OperationStatus::Cancelled
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn data_lock_prevents_two_daemons_from_sharing_state() {
        let dir = temp_dir("lock");
        let first = DataLock::acquire(&dir).unwrap();
        let error = DataLock::acquire(&dir).err().unwrap();
        assert_eq!(error.kind(), io::ErrorKind::AddrInUse);
        drop(first);
        let second = DataLock::acquire(&dir).unwrap();
        drop(second);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn first_load_creates_default_identity_and_persists_it() {
        let dir = temp_dir("identity");
        let store = Store::load(&dir).unwrap();
        assert_eq!(store.identities.len(), 1);
        assert_eq!(store.identities[0].id, "default");
        assert!(store.identities[0].public_key.is_some());
        assert!(dir.join("state.json").is_file());
        assert!(dir.join("identity-default.key").is_file());

        let reloaded = Store::load(&dir).unwrap();
        assert_eq!(reloaded.identities, store.identities);
        assert!(reloaded.peers.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn peer_resolution_matches_name_alias_and_endpoint() {
        let dir = temp_dir("resolve");
        let mut store = Store::load(&dir).unwrap();
        store.peers.push(nufon_protocol::Peer {
            id: "peer-1".into(),
            name: "Alice".into(),
            endpoint_id: Some("ep-1".into()),
            endpoint_addr: None,
            aliases: vec!["alice@work".into()],
        });
        store.save(&dir).unwrap();
        let store = Arc::new(Mutex::new(Store::load(&dir).unwrap()));

        for reference in ["peer-1", "Alice", "alice@work", "ep-1"] {
            let response = dispatch(
                Request {
                    version: PROTOCOL_VERSION,
                    id: "test".into(),
                    method: "peer.resolve".into(),
                    params: serde_json::json!({"ref": reference}),
                },
                &store,
            );
            assert!(response.ok, "resolution failed for {reference}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn peer_resolution_reports_ambiguity() {
        let dir = temp_dir("ambiguous");
        let mut store = Store::load(&dir).unwrap();
        for id in ["peer-1", "peer-2"] {
            store.peers.push(nufon_protocol::Peer {
                id: id.into(),
                name: "same".into(),
                endpoint_id: None,
                endpoint_addr: None,
                aliases: Vec::new(),
            });
        }
        store.save(&dir).unwrap();
        let store = Arc::new(Mutex::new(Store::load(&dir).unwrap()));
        let response = dispatch(
            Request {
                version: PROTOCOL_VERSION,
                id: "test".into(),
                method: "peer.resolve".into(),
                params: serde_json::json!({"ref": "same"}),
            },
            &store,
        );
        assert!(!response.ok);
        assert!(matches!(
            response.body,
            ResponseBody::Failure {
                error: ApiError {
                    code: ErrorCode::AmbiguousPeer,
                    ..
                },
                ..
            }
        ));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
