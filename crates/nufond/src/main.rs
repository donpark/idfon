#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::{
    io,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
};

mod blob;

use nufon_core::transport::{FakeTransport, MessageTransport};
use nufon_media::service::MediaService;
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
const EVENT_RETENTION: usize = 1000;
const MAX_RESOURCE_BYTES: usize = 512 * 1024;
static MEDIA_SERVICE: OnceLock<MediaService> = OnceLock::new();

enum TransportMode {
    Fake(FakeTransport),
    Iroh(Arc<nufon_core::transport::TransportManager>),
}

impl TransportMode {
    async fn new(name: &str, key: Option<[u8; 32]>) -> io::Result<Self> {
        match name {
            "fake" => Ok(Self::Fake(FakeTransport::default())),
            "iroh" => nufon_core::transport::TransportManager::bind_with_key(key)
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
            Self::Iroh(transport) => Some(transport.endpoint_id()),
        }
    }

    fn endpoint_ticket(&self) -> Option<Vec<u8>> {
        match self {
            Self::Fake(_) => None,
            Self::Iroh(transport) => transport.endpoint_ticket(),
        }
    }

    fn rebind(&self, key: [u8; 32]) -> io::Result<Option<String>> {
        let Self::Iroh(manager) = self else { return Ok(None); };
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let runtime = tokio::runtime::Runtime::new()?;
                runtime.block_on(manager.rebind(Some(key))).map(Some).map_err(io::Error::other)
            }).join().map_err(|_| io::Error::other("rebind worker panicked"))?
        })
    }

    fn send(&self, peer: &nufon_protocol::Peer, message: &nufon_protocol::MessageEnvelope) -> io::Result<nufon_protocol::MessageAck> {
        let address = if matches!(self, Self::Fake(_)) {
            "0000000000000000000000000000000000000000000000000000000000000000"
        } else {
            peer.endpoint_addr.as_deref().ok_or_else(|| io::Error::other("peer has no endpoint address"))?
        };
        let target = serde_json::from_str(address).map_err(|error| io::Error::other(format!("invalid endpoint address: {error}")))?;
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let runtime = tokio::runtime::Runtime::new()?;
                match self {
                    Self::Fake(transport) => runtime.block_on(transport.send(&target, message)),
                    Self::Iroh(transport) => runtime.block_on(transport.send(&target, message)),
                }.map_err(io::Error::other)
            }).join().map_err(|_| io::Error::other("transport worker panicked"))?
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
    #[serde(default)]
    policies: Vec<nufon_protocol::LocalPolicy>,
    #[serde(default)]
    resources: Vec<nufon_protocol::MediaResource>,
    #[serde(default)]
    sessions: Vec<nufon_protocol::MediaSession>,
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
                    policies: Vec::new(),
                    resources: Vec::new(),
                    sessions: Vec::new(),
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
    let media_service = Arc::new(MediaService::default());
    let _ = MEDIA_SERVICE.set((*media_service).clone());
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
        let request = match serde_json::from_slice::<Request>(&frame) {
            Ok(request) => request,
            Err(error) => {
                let response = error_response(
                    "unknown".into(),
                    "protocol",
                    ErrorCode::InvalidJson,
                    error.to_string(),
                    false,
                );
                write_frame(
                    &mut stream,
                    &encode_json(&response).map_err(io::Error::other)?,
                )
                .await?;
                continue;
            }
        };
        if request.method == "wait" {
            let timeout = request
                .params
                .get("timeout_ms")
                .and_then(serde_json::Value::as_u64)
                .unwrap_or(30_000)
                .min(300_000);
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(timeout);
            loop {
                let response = dispatch_with_transport(request.clone(), &store, &transport);
                let found = matches!(&response.body, ResponseBody::Success { result, .. } if result.get("events").and_then(serde_json::Value::as_array).is_some_and(|events| !events.is_empty()));
                if found || tokio::time::Instant::now() >= deadline {
                    write_frame(
                        &mut stream,
                        &encode_json(&response).map_err(io::Error::other)?,
                    )
                    .await?;
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
            continue;
        }
        if request.method == "events"
            && request
                .params
                .get("follow")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false)
        {
            let mut follow_request = request;
            loop {
                let response = dispatch_with_transport(follow_request.clone(), &store, &transport);
                if let ResponseBody::Success { result, .. } = &response.body {
                    if let Some(last) = result
                        .get("events")
                        .and_then(serde_json::Value::as_array)
                        .and_then(|events| events.last())
                        .and_then(|event| event.get("cursor"))
                        .cloned()
                    {
                        if let Some(params) = follow_request.params.as_object_mut() {
                            params.insert("after".into(), last);
                        }
                    }
                }
                write_frame(
                    &mut stream,
                    &encode_json(&response).map_err(io::Error::other)?,
                )
                .await?;
                tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            }
        }
        if request.method == "peers.compact" {
            let payload = compact_peers(&store);
            write_frame(&mut stream, &payload).await?;
            continue;
        }
        if request.method == "identities.compact" {
            let payload = compact_identities(&store);
            write_frame(&mut stream, &payload).await?;
            continue;
        }
        if request.method == "events.compact" {
            let after = request_text(&request.params, "after");
            let payload = compact_events(&store, after.as_deref());
            write_frame(&mut stream, &payload).await?;
            continue;
        }
        let response = dispatch_with_transport(request, &store, &transport);
        write_frame(
            &mut stream,
            &encode_json(&response).map_err(io::Error::other)?,
        )
        .await?
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
        "operation.wait" => operation_wait(&request, store),
        "operation.cancel" => operation_cancel(&request, store),
        "events" => events(&request, store),
        "wait" => wait_event(&request, store),
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
                    "ticket": transport.endpoint_ticket().unwrap_or_default(),
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
        "identities.compact" => success(&request, serde_json::json!(compact_identities(store))),
        "peers" => {
            let state = store.lock().expect("store mutex poisoned");
            success(&request, serde_json::json!({"peers": state.peers}))
        }
        "peer.add" => peer_add(&request, store),
        "peer.update" => peer_update(&request, store),
        "peer.remove" => peer_remove(&request, store),
        "peer.show" | "peer.status" => {
            let reference = request
                .params
                .get("ref")
                .and_then(serde_json::Value::as_str);
            let state = store.lock().expect("store mutex poisoned");
            let peer = state.peers.iter().find(|peer| {
                reference.is_some_and(|reference| {
                    peer.id == reference
                        || peer.name == reference
                        || peer.aliases.iter().any(|alias| alias == reference)
                        || peer.endpoint_id.as_deref() == Some(reference)
                })
            });
            match peer {
                Some(peer) => success(
                    &request,
                    serde_json::json!({"peer": peer, "status": "known"}),
                ),
                None => error_response(
                    request.id,
                    &request.method,
                    ErrorCode::InvalidRequest,
                    "peer not found".into(),
                    false,
                ),
            }
        }
        "access.grant" => access_grant(&request, store),
        "access.revoke" => access_revoke(&request, store),
        "access.check" => access_check(&request, store),
        "media.session.start" => media_session_start(&request, store),
        "media.session.stop" => media_session_stop(&request, store),
        "media.resource.register" => media_resource_register(&request, store),
        "media.resource.put" => media_resource_put(&request, store),
        "media.resource.fetch" => media_resource_fetch(&request, store),
        "media.resource.get" => media_resource_get(&request, store),
        "media.resource.delete" => media_resource_delete(&request, store),
        "media.resource.gc" => media_resource_gc(&request, store),
        "media.resources" => media_resources(&request, store),
        "media.sessions" => media_sessions(&request, store),
        "policy.set" => policy_set(&request, store),
        "policy.dry_run" => policy_dry_run(&request, store),
        "identity.create" => identity_create(&request, store),
        "identity.delete" => identity_delete(&request, store),
        "identity.use" => {
            let name = request
                .params
                .get("name")
                .and_then(serde_json::Value::as_str);
            let mut state = store.lock().expect("store mutex poisoned");
            let found = state.identities.iter().any(|identity| {
                name.is_some_and(|name| identity.id == name || identity.name == name)
            });
            if !found {
                return error_response(
                    request.id,
                    &request.method,
                    ErrorCode::InvalidRequest,
                    "identity not found".into(),
                    false,
                );
            }
            let identity_id = state
                .identities
                .iter()
                .find(|identity| {
                    identity.id == name.unwrap_or_default()
                        || identity.name == name.unwrap_or_default()
                })
                .map(|identity| identity.id.clone())
                .unwrap();
            let key = match state.identity_key(&identity_id) {
                Ok(key) => key,
                Err(error) => {
                    return error_response(
                        request.id,
                        &request.method,
                        ErrorCode::Internal,
                        error.to_string(),
                        false,
                    )
                }
            };
            let endpoint_id = match transport.rebind(nufon_core::signing_key_bytes(&key)) {
                Ok(endpoint_id) => endpoint_id,
                Err(error) => {
                    return error_response(
                        request.id,
                        &request.method,
                        ErrorCode::Internal,
                        error.to_string(),
                        true,
                    )
                }
            };
            for identity in &mut state.identities {
                identity.active = identity.id == identity_id;
            }
            if let Some(endpoint_id) = endpoint_id {
                if let Some(identity) = state.identities.iter_mut().find(|identity| identity.active)
                {
                    identity.endpoint_id = Some(endpoint_id);
                }
            }
            let data_dir = state.data_dir.clone();
            if let Err(error) = state.save(&data_dir) {
                return error_response(
                    request.id,
                    &request.method,
                    ErrorCode::Internal,
                    error.to_string(),
                    true,
                );
            }
            success(
                &request,
                serde_json::json!({"identity": name, "active": true}),
            )
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

fn request_text(params: &serde_json::Value, name: &str) -> Option<String> {
    if let Some(value) = params.get(name).and_then(serde_json::Value::as_str) {
        return Some(value.to_owned());
    }
    let bytes = params
        .get(&format!("{name}_bytes"))
        .and_then(serde_json::Value::as_array)?;
    let mut output = String::with_capacity(bytes.len());
    for byte in bytes {
        output.push(byte.as_u64()?.try_into().ok().and_then(char::from_u32)?);
    }
    Some(output)
}

fn send_message(
    request: &Request,
    store: &Arc<Mutex<Store>>,
    transport: &Arc<TransportMode>,
) -> Response {
    let to = request_text(&request.params, "to");
    let text = request_text(&request.params, "text");
    let key = request_text(&request.params, "idempotency_key");
    let retries = request
        .params
        .get("retries")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0)
        .min(3) as usize;
    if to.is_none()
        || text.is_none()
        || key.is_none()
        || text.as_deref().is_some_and(str::is_empty)
        || key.as_deref().is_some_and(str::is_empty)
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
        peer.id == to || peer.name == to || peer.aliases.iter().any(|alias| alias == &to)
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
            && grant
                .expires_at
                .as_deref()
                .is_none_or(|expires| expires > now().as_str())
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
            && operation.idempotency_key.as_deref() == Some(&key)
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
        &key,
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
        if state.events.len() > EVENT_RETENTION {
            let excess = state.events.len() - EVENT_RETENTION;
            state.events.drain(..excess);
        }
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
        data: serde_json::json!({"message_id": envelope.message_id, "peer_id": envelope.sender.peer_id, "text": match &envelope.content { nufon_protocol::MessageContent::Text { text } => text }}),
    });
    if state.events.len() > EVENT_RETENTION {
        let excess = state.events.len() - EVENT_RETENTION;
        state.events.drain(..excess);
    }
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

fn operation_wait(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let id = request
        .params
        .get("operation_id")
        .and_then(serde_json::Value::as_str);
    let Some(id) = id else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "operation_id is required".into(),
            false,
        );
    };
    let state = store.lock().expect("store mutex poisoned");
    match state
        .operations
        .iter()
        .find(|operation| operation.operation_id == id)
    {
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

fn capability(value: &str) -> Option<nufon_protocol::Capability> {
    serde_json::from_value(serde_json::Value::String(value.replace('.', "_"))).ok()
}

fn access_grant(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(identity) = request
        .params
        .get("identity")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "identity is required".into(),
            false,
        );
    };
    let Some(subject) = request
        .params
        .get("subject")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "subject is required".into(),
            false,
        );
    };
    let Some(value) = request
        .params
        .get("capability")
        .and_then(serde_json::Value::as_str)
        .and_then(capability)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "unknown capability".into(),
            false,
        );
    };
    let mut state = store.lock().expect("store mutex poisoned");
    let revision = state
        .grants
        .iter()
        .filter(|grant| {
            grant.identity == identity && grant.subject == subject && grant.capability == value
        })
        .map(|grant| grant.revision)
        .max()
        .unwrap_or(0)
        + 1;
    let grant = nufon_protocol::CapabilityGrant {
        capability: value,
        identity: identity.into(),
        subject: subject.into(),
        conversation: request
            .params
            .get("conversation")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        active_at: request
            .params
            .get("active_at")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("0")
            .into(),
        expires_at: request
            .params
            .get("expires_at")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        revision,
        revoked_at: None,
    };
    state.grants.push(grant.clone());
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
    success(request, serde_json::json!({"grant": grant}))
}

fn access_revoke(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(identity) = request
        .params
        .get("identity")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "identity is required".into(),
            false,
        );
    };
    let Some(subject) = request
        .params
        .get("subject")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "subject is required".into(),
            false,
        );
    };
    let Some(value) = request
        .params
        .get("capability")
        .and_then(serde_json::Value::as_str)
        .and_then(capability)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "unknown capability".into(),
            false,
        );
    };
    let mut state = store.lock().expect("store mutex poisoned");
    let mut changed = false;
    for grant in &mut state.grants {
        if grant.identity == identity
            && grant.subject == subject
            && grant.capability == value
            && grant.revoked_at.is_none()
        {
            grant.revoked_at = Some(now());
            changed = true;
        }
    }
    if !changed {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "grant not found".into(),
            false,
        );
    }
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
    success(request, serde_json::json!({"revoked": true}))
}

fn access_check(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(identity) = request
        .params
        .get("identity")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "identity is required".into(),
            false,
        );
    };
    let Some(subject) = request
        .params
        .get("subject")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "subject is required".into(),
            false,
        );
    };
    let Some(value) = request
        .params
        .get("capability")
        .and_then(serde_json::Value::as_str)
        .and_then(capability)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "unknown capability".into(),
            false,
        );
    };
    let state = store.lock().expect("store mutex poisoned");
    let allowed = state.grants.iter().any(|grant| {
        grant.identity == identity
            && grant.subject == subject
            && grant.capability == value
            && grant.revoked_at.is_none()
            && grant
                .expires_at
                .as_deref()
                .is_none_or(|expires| expires > now().as_str())
    });
    success(
        request,
        serde_json::json!({"allowed": allowed, "identity": identity, "subject": subject, "capability": value}),
    )
}

fn media_capability(kind: &nufon_protocol::MediaKind) -> nufon_protocol::Capability {
    match kind {
        nufon_protocol::MediaKind::File => nufon_protocol::Capability::RecordingFetch,
        nufon_protocol::MediaKind::Recording => nufon_protocol::Capability::RecordingFetch,
        nufon_protocol::MediaKind::LiveAudio => nufon_protocol::Capability::LiveAudioSubscribe,
        nufon_protocol::MediaKind::LiveVideo => nufon_protocol::Capability::LiveAudioSubscribe,
    }
}

fn media_session_start(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(identity) = request_text(&request.params, "identity") else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "identity is required".into(),
            false,
        );
    };
    let Some(peer) = request_text(&request.params, "peer") else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "peer is required".into(),
            false,
        );
    };
    let Some(kind) = request
        .params
        .get("kind")
        .and_then(|value| serde_json::from_value(value.clone()).ok())
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "valid media kind is required".into(),
            false,
        );
    };
    let capability = media_capability(&kind);
    let mut state = store.lock().expect("store mutex poisoned");
    let allowed = state.grants.iter().any(|grant| {
        grant.identity == identity
            && grant.subject == peer
            && grant.capability == capability
            && grant.revoked_at.is_none()
            && grant
                .expires_at
                .as_deref()
                .is_none_or(|expires| expires > now().as_str())
    });
    if !allowed {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::CapabilityDenied,
            "media capability denied".into(),
            false,
        );
    }
    let session = nufon_protocol::MediaSession {
        session_id: format!("session_{}", state.sessions.len() + 1),
        identity: identity.clone(),
        peer: peer.clone(),
        conversation: request
            .params
            .get("conversation")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        kind,
        capability,
        active: true,
        created_at: now(),
    };
    let media_handle = MEDIA_SERVICE.get().map(|service| {
        service.start(
            session.session_id.clone(),
            session.identity.clone(),
            session.peer.clone(),
            session.kind.clone(),
            session.capability.clone(),
        )
    });
    let mode = request
        .params
        .get("mode")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("record");
    let live_ticket = if session.kind == nufon_protocol::MediaKind::LiveAudio && mode == "publish" {
        let Some(handle) = media_handle.clone() else {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::Internal,
                "media service unavailable".into(),
                true,
            );
        };
        match std::thread::spawn(move || {
            tokio::runtime::Runtime::new()
                .unwrap()
                .block_on(handle.start_publisher())
        })
        .join()
        {
            Ok(Ok(ticket)) => Some(ticket),
            Ok(Err(error)) => {
                return error_response(
                    request.id.clone(),
                    &request.method,
                    ErrorCode::Internal,
                    error.to_string(),
                    true,
                )
            }
            Err(_) => {
                return error_response(
                    request.id.clone(),
                    &request.method,
                    ErrorCode::Internal,
                    "media worker panicked".into(),
                    true,
                )
            }
        }
    } else if session.kind == nufon_protocol::MediaKind::LiveAudio && mode == "subscribe" {
        let Some(ticket) = request
            .params
            .get("ticket")
            .and_then(serde_json::Value::as_str)
        else {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::InvalidRequest,
                "ticket is required".into(),
                false,
            );
        };
        let Some(handle) = media_handle else {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::Internal,
                "media service unavailable".into(),
                true,
            );
        };
        let ticket = ticket.to_owned();
        match std::thread::spawn(move || {
            tokio::runtime::Runtime::new()
                .unwrap()
                .block_on(handle.start_subscriber(&ticket))
        })
        .join()
        {
            Ok(Ok(())) => None,
            Ok(Err(error)) => {
                return error_response(
                    request.id.clone(),
                    &request.method,
                    ErrorCode::Internal,
                    error.to_string(),
                    true,
                )
            }
            Err(_) => {
                return error_response(
                    request.id.clone(),
                    &request.method,
                    ErrorCode::Internal,
                    "media worker panicked".into(),
                    true,
                )
            }
        }
    } else {
        None
    };
    state.sessions.push(session.clone());
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
        serde_json::json!({"session": session, "live_ticket": live_ticket}),
    )
}

fn media_session_stop(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(id) = request
        .params
        .get("session_id")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "session_id is required".into(),
            false,
        );
    };
    let mut state = store.lock().expect("store mutex poisoned");
    let Some(session) = state
        .sessions
        .iter_mut()
        .find(|session| session.session_id == id)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "session not found".into(),
            false,
        );
    };
    session.active = false;
    if let Some(service) = MEDIA_SERVICE.get() {
        if let Ok(handle) = service.get(id) {
            let _ = std::thread::spawn(move || {
                tokio::runtime::Runtime::new()
                    .unwrap()
                    .block_on(handle.stop_publisher())
            })
            .join();
        }
        let _ = service.stop(id);
    }
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
        serde_json::json!({"session_id": id, "active": false}),
    )
}

fn media_resource_put(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(id) = request
        .params
        .get("resource_id")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "resource_id is required".into(),
            false,
        );
    };
    let Some(bytes) = request
        .params
        .get("bytes")
        .and_then(serde_json::Value::as_array)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "bytes are required".into(),
            false,
        );
    };
    if bytes.len() > MAX_RESOURCE_BYTES {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::FrameTooLarge,
            "resource is too large".into(),
            false,
        );
    }
    let mut data = Vec::with_capacity(bytes.len());
    for byte in bytes {
        let Some(byte) = byte.as_u64().and_then(|value| u8::try_from(value).ok()) else {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::InvalidRequest,
                "bytes must be 0..255".into(),
                false,
            );
        };
        data.push(byte);
    }
    let state = store.lock().expect("store mutex poisoned");
    let path = state.data_dir.join("resources").join(id);
    if let Some(parent) = path.parent() {
        if let Err(error) = std::fs::create_dir_all(parent) {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::Internal,
                error.to_string(),
                true,
            );
        }
    }
    if let Err(error) = std::fs::write(&path, &data) {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::Internal,
            error.to_string(),
            true,
        );
    }
    let blob_ticket = match blob::run_put(state.data_dir.join("blobs"), data.clone()) {
        Ok((ticket, _)) => ticket.to_string(),
        Err(error) => {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::Internal,
                error.to_string(),
                true,
            )
        }
    };
    success(
        request,
        serde_json::json!({"resource_id": id, "size_bytes": data.len(), "content_hash": blake3::hash(&data).to_hex().to_string(), "blob_ticket": blob_ticket}),
    )
}

fn media_resource_fetch(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(id) = request
        .params
        .get("resource_id")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "resource_id is required".into(),
            false,
        );
    };
    let state = store.lock().expect("store mutex poisoned");
    let bytes = if let Some(ticket) = request
        .params
        .get("blob_ticket")
        .and_then(serde_json::Value::as_str)
    {
        match blob::run_fetch(ticket.into(), state.data_dir.join("blobs-fetched")) {
            Ok(path) => std::fs::read(path),
            Err(error) => {
                return error_response(
                    request.id.clone(),
                    &request.method,
                    ErrorCode::PeerOffline,
                    error.to_string(),
                    true,
                )
            }
        }
    } else {
        std::fs::read(state.data_dir.join("resources").join(id))
    };
    match bytes {
        Ok(bytes) => success(
            request,
            serde_json::json!({"resource_id": id, "bytes": bytes}),
        ),
        Err(error) if error.kind() == io::ErrorKind::NotFound => error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "resource not found".into(),
            false,
        ),
        Err(error) => error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::Internal,
            error.to_string(),
            true,
        ),
    }
}

fn media_resource_register(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let resource: nufon_protocol::MediaResource =
        match serde_json::from_value(request.params.get("resource").cloned().unwrap_or_default()) {
            Ok(resource) => resource,
            Err(error) => {
                return error_response(
                    request.id.clone(),
                    &request.method,
                    ErrorCode::InvalidRequest,
                    error.to_string(),
                    false,
                )
            }
        };
    let mut state = store.lock().expect("store mutex poisoned");
    if state
        .resources
        .iter()
        .any(|item| item.resource_id == resource.resource_id)
    {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "resource already exists".into(),
            false,
        );
    }
    state.resources.push(resource.clone());
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
    success(request, serde_json::json!({"resource": resource}))
}

fn media_resource_get(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(id) = request
        .params
        .get("resource_id")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "resource_id is required".into(),
            false,
        );
    };
    let state = store.lock().expect("store mutex poisoned");
    match state
        .resources
        .iter()
        .find(|resource| resource.resource_id == id)
    {
        Some(resource) => success(request, serde_json::json!({"resource": resource})),
        None => error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "resource not found".into(),
            false,
        ),
    }
}

fn media_resource_delete(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(id) = request
        .params
        .get("resource_id")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "resource_id is required".into(),
            false,
        );
    };
    let mut state = store.lock().expect("store mutex poisoned");
    let before = state.resources.len();
    state
        .resources
        .retain(|resource| resource.resource_id != id);
    let _ = std::fs::remove_file(state.data_dir.join("resources").join(id));
    if before == state.resources.len() {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "resource not found".into(),
            false,
        );
    }
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
    success(request, serde_json::json!({"deleted": id}))
}

fn media_resource_gc(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let mut state = store.lock().expect("store mutex poisoned");
    let mut removed = 0usize;
    let data_root = state.data_dir.join("resources");
    let resources = std::mem::take(&mut state.resources);
    let mut kept = Vec::with_capacity(resources.len());
    for resource in resources {
        if data_root.join(&resource.resource_id).exists() {
            kept.push(resource);
        } else {
            removed += 1;
        }
    }
    state.resources = kept;
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
    success(request, serde_json::json!({"removed": removed}))
}

fn media_resources(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let state = store.lock().expect("store mutex poisoned");
    success(request, serde_json::json!({"resources": state.resources}))
}

fn media_sessions(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let state = store.lock().expect("store mutex poisoned");
    success(request, serde_json::json!({"sessions": state.sessions}))
}

fn policy_set(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let required = ["id", "identity", "subject", "mode", "delivery"];
    if required.iter().any(|field| {
        request
            .params
            .get(*field)
            .and_then(serde_json::Value::as_str)
            .is_none()
    }) {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "id, identity, subject, mode, and delivery are required".into(),
            false,
        );
    }
    let start = request
        .params
        .get("schedule_start")
        .and_then(serde_json::Value::as_u64)
        .map(|value| value as u8);
    let end = request
        .params
        .get("schedule_end")
        .and_then(serde_json::Value::as_u64)
        .map(|value| value as u8);
    if start.is_some_and(|value| value > 23)
        || end.is_some_and(|value| value > 24)
        || start.is_some() != end.is_some()
        || start.zip(end).is_some_and(|(start, end)| start >= end)
    {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "schedule must be a valid start/end hour window".into(),
            false,
        );
    }
    let mut state = store.lock().expect("store mutex poisoned");
    let id = request.params["id"].as_str().unwrap();
    let revision = state
        .policies
        .iter()
        .filter(|policy| policy.id == id)
        .map(|policy| policy.revision)
        .max()
        .unwrap_or(0)
        + 1;
    let policy = nufon_protocol::LocalPolicy {
        id: id.into(),
        identity: request.params["identity"].as_str().unwrap().into(),
        subject: request.params["subject"].as_str().unwrap().into(),
        mode: request.params["mode"].as_str().unwrap().into(),
        delivery: request.params["delivery"].as_str().unwrap().into(),
        notify: request
            .params
            .get("notify")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(true),
        auto_accept: request
            .params
            .get("auto_accept")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
        interrupt: request
            .params
            .get("interrupt")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
        record: request
            .params
            .get("record")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
        expires_at: request
            .params
            .get("expires_at")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        schedule_start: start,
        schedule_end: end,
        revision,
    };
    state.policies.retain(|existing| existing.id != policy.id);
    state.policies.push(policy.clone());
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
    success(request, serde_json::json!({"policy": policy}))
}

fn policy_dry_run(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let peer = request
        .params
        .get("peer")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    let mode = request
        .params
        .get("mode")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("text");
    let state = store.lock().expect("store mutex poisoned");
    let policy = state
        .policies
        .iter()
        .find(|policy| policy.subject == peer && policy.mode == mode);
    let hour = request
        .params
        .get("hour")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0) as u8;
    let decision = policy
        .filter(|policy| {
            policy
                .expires_at
                .as_deref()
                .is_none_or(|expires| expires > now().as_str())
        })
        .filter(|policy| {
            policy
                .schedule_start
                .zip(policy.schedule_end)
                .is_none_or(|(start, end)| hour >= start && hour < end)
        })
        .map(|policy| {
            if policy.auto_accept {
                "accept"
            } else if policy.notify {
                "notify"
            } else {
                "queue"
            }
        })
        .unwrap_or("reject");
    success(
        request,
        serde_json::json!({"decision": decision, "peer": peer, "mode": mode}),
    )
}

fn identity_create(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(name) = request
        .params
        .get("name")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "name is required".into(),
            false,
        );
    };
    let mut state = store.lock().expect("store mutex poisoned");
    if state
        .identities
        .iter()
        .any(|identity| identity.id == name || identity.name == name)
    {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "identity already exists".into(),
            false,
        );
    }
    let identity = Identity {
        id: name.into(),
        name: name.into(),
        endpoint_id: None,
        public_key: None,
        active: false,
    };
    state.identities.push(identity.clone());
    let data_dir = state.data_dir.clone();
    if let Err(error) = state.ensure_identity_keys(&data_dir) {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::Internal,
            error.to_string(),
            true,
        );
    }
    success(request, serde_json::json!({"identity": identity}))
}

fn identity_delete(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(name) = request
        .params
        .get("name")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "name is required".into(),
            false,
        );
    };
    let mut state = store.lock().expect("store mutex poisoned");
    let Some(index) = state
        .identities
        .iter()
        .position(|identity| identity.id == name || identity.name == name)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "identity not found".into(),
            false,
        );
    };
    if state.identities[index].active || state.identities.len() == 1 {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "cannot delete active or last identity".into(),
            false,
        );
    }
    let id = state.identities.remove(index).id;
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
    let _ = std::fs::remove_file(data_dir.join(format!("identity-{id}.key")));
    success(request, serde_json::json!({"deleted": id}))
}

fn peer_add(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(id) = request
        .params
        .get("id")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "id is required".into(),
            false,
        );
    };
    let name = request
        .params
        .get("name")
        .and_then(serde_json::Value::as_str)
        .unwrap_or(id);
    let mut state = store.lock().expect("store mutex poisoned");
    if state
        .peers
        .iter()
        .any(|peer| peer.id == id || peer.name == name)
    {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "peer already exists".into(),
            false,
        );
    }
    let peer = nufon_protocol::Peer {
        id: id.into(),
        name: name.into(),
        endpoint_id: request
            .params
            .get("endpoint_id")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        endpoint_addr: request
            .params
            .get("endpoint_addr")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned),
        aliases: request
            .params
            .get("aliases")
            .and_then(serde_json::Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(serde_json::Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default(),
    };
    state.peers.push(peer.clone());
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
    success(request, serde_json::json!({"peer": peer}))
}

fn peer_update(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(reference) = request
        .params
        .get("ref")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "ref is required".into(),
            false,
        );
    };
    let mut state = store.lock().expect("store mutex poisoned");
    let Some(peer) = state.peers.iter_mut().find(|peer| {
        peer.id == reference
            || peer.name == reference
            || peer.aliases.iter().any(|alias| alias == reference)
    }) else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "peer not found".into(),
            false,
        );
    };
    if let Some(name) = request
        .params
        .get("name")
        .and_then(serde_json::Value::as_str)
    {
        if name.is_empty() {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::InvalidRequest,
                "name cannot be empty".into(),
                false,
            );
        }
        peer.name = name.into();
    }
    if let Some(endpoint_id) = request
        .params
        .get("endpoint_id")
        .and_then(serde_json::Value::as_str)
    {
        peer.endpoint_id = Some(endpoint_id.into());
    }
    if let Some(endpoint_addr) = request
        .params
        .get("endpoint_addr")
        .and_then(serde_json::Value::as_str)
    {
        if serde_json::from_str::<serde_json::Value>(endpoint_addr).is_err() {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::InvalidRequest,
                "endpoint_addr must be valid JSON".into(),
                false,
            );
        }
        peer.endpoint_addr = Some(endpoint_addr.into());
    }
    if let Some(aliases) = request
        .params
        .get("aliases")
        .and_then(serde_json::Value::as_array)
    {
        peer.aliases = aliases
            .iter()
            .filter_map(serde_json::Value::as_str)
            .map(str::to_owned)
            .collect();
    }
    let updated = peer.clone();
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
    success(request, serde_json::json!({"peer": updated}))
}

fn peer_remove(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let Some(reference) = request
        .params
        .get("ref")
        .and_then(serde_json::Value::as_str)
    else {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "ref is required".into(),
            false,
        );
    };
    let mut state = store.lock().expect("store mutex poisoned");
    let before = state.peers.len();
    state.peers.retain(|peer| {
        !(peer.id == reference
            || peer.name == reference
            || peer.aliases.iter().any(|alias| alias == reference))
    });
    if state.peers.len() == before {
        return error_response(
            request.id.clone(),
            &request.method,
            ErrorCode::InvalidRequest,
            "peer not found".into(),
            false,
        );
    }
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
    success(request, serde_json::json!({"removed": reference}))
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

fn wait_event(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let mut response = events(request, store);
    if let ResponseBody::Success { ref mut result, .. } = response.body {
        if let Some(events) = result
            .get_mut("events")
            .and_then(serde_json::Value::as_array_mut)
        {
            events.truncate(1);
        }
    }
    response
}

fn compact_identities(store: &Arc<Mutex<Store>>) -> Vec<u8> {
    let state = store.lock().expect("store mutex poisoned");
    let mut payload = Vec::new();
    payload.extend_from_slice(&(state.identities.len() as u16).to_be_bytes());
    for identity in &state.identities {
        let name = identity.name.as_bytes();
        if name.len() > u16::MAX as usize { return Vec::new(); }
        payload.extend_from_slice(&(name.len() as u16).to_be_bytes());
        payload.extend_from_slice(name);
        payload.push(if identity.active { 1 } else { 0 });
    }
    payload
}

fn compact_peers(store: &Arc<Mutex<Store>>) -> Vec<u8> {
    let state = store.lock().expect("store mutex poisoned");
    let mut payload = Vec::new();
    payload.extend_from_slice(&(state.peers.len() as u16).to_be_bytes());
    for peer in &state.peers {
        let name = peer.name.as_bytes();
        let endpoint = peer.endpoint_id.as_deref().unwrap_or("").as_bytes();
        if name.len() > u16::MAX as usize || endpoint.len() > u16::MAX as usize {
            continue;
        }
        payload.extend_from_slice(&(name.len() as u16).to_be_bytes());
        payload.extend_from_slice(name);
        payload.extend_from_slice(&(endpoint.len() as u16).to_be_bytes());
        payload.extend_from_slice(endpoint);
    }
    payload
}

fn compact_events(store: &Arc<Mutex<Store>>, after: Option<&str>) -> Vec<u8> {
    let state = store.lock().expect("store mutex poisoned");
    let events: Vec<_> = state
        .events
        .iter()
        .filter(|event| after.is_none_or(|cursor| event.cursor.as_str() > cursor))
        .collect();
    let mut payload = Vec::new();
    payload.extend_from_slice(&(events.len() as u16).to_be_bytes());
    for event in events {
        let cursor = event.cursor.as_bytes();
        let kind = event.r#type.as_bytes();
        let peer = event
            .data
            .get("peer_id")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .as_bytes();
        let message = event
            .data
            .get("message_id")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .as_bytes();
        let text = event
            .data
            .get("text")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("")
            .as_bytes();
        for value in [cursor, kind, peer, message, text] {
            if value.len() > u16::MAX as usize {
                return Vec::new();
            }
            payload.extend_from_slice(&(value.len() as u16).to_be_bytes());
            payload.extend_from_slice(value);
        }
    }
    payload
}

fn events(request: &Request, store: &Arc<Mutex<Store>>) -> Response {
    let after = request
        .params
        .get("after")
        .and_then(serde_json::Value::as_str);
    let kind = request
        .params
        .get("type")
        .and_then(serde_json::Value::as_str);
    let peer = request
        .params
        .get("peer")
        .and_then(serde_json::Value::as_str);
    let state = store.lock().expect("store mutex poisoned");
    if let (Some(after), Some(oldest)) = (after, state.events.first()) {
        if !after.is_empty() && after < oldest.cursor.as_str() {
            return error_response(
                request.id.clone(),
                &request.method,
                ErrorCode::CursorTooOld,
                "event cursor is older than retained history".into(),
                false,
            );
        }
    }
    let events: Vec<_> = state
        .events
        .iter()
        .rev()
        .take(EVENT_RETENTION)
        .filter(|event| {
            after.is_none_or(|cursor| event.cursor.as_str() > cursor)
                && kind.is_none_or(|value| event.r#type == value)
                && peer.is_none_or(|value| {
                    event
                        .data
                        .get("peer_id")
                        .and_then(serde_json::Value::as_str)
                        == Some(value)
                })
        })
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
    fn identity_and_peer_mutations_persist() {
        let dir = temp_dir("management");
        let store = Arc::new(Mutex::new(Store::load(&dir).unwrap()));
        let create = dispatch(
            Request {
                version: PROTOCOL_VERSION,
                id: "create".into(),
                method: "identity.create".into(),
                params: serde_json::json!({"name": "work"}),
            },
            &store,
        );
        assert!(create.ok);
        let add = dispatch(
            Request {
                version: PROTOCOL_VERSION,
                id: "add".into(),
                method: "peer.add".into(),
                params: serde_json::json!({"id": "peer-1", "name": "Alice", "aliases": ["alice@work"]}),
            },
            &store,
        );
        assert!(add.ok);
        let state = Store::load(&dir).unwrap();
        assert_eq!(state.identities.len(), 2);
        assert_eq!(state.peers[0].aliases, vec!["alice@work"]);
        assert!(dir.join("identity-work.key").is_file());
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
    fn event_queries_filter_and_reject_old_cursors() {
        let dir = temp_dir("events");
        let store = Arc::new(Mutex::new(Store::load(&dir).unwrap()));
        {
            let mut state = store.lock().unwrap();
            state.events = vec![nufon_protocol::Event {
                event_id: "evt-2".into(),
                cursor: "cur_00000000000000000002".into(),
                r#type: "message.received".into(),
                timestamp: now(),
                identity: "default".into(),
                data: serde_json::json!({"peer_id": "alice"}),
            }];
        }
        let filtered = dispatch(
            Request {
                version: PROTOCOL_VERSION,
                id: "test".into(),
                method: "events".into(),
                params: serde_json::json!({"after": "cur_00000000000000000002", "type": "message.received", "peer": "alice"}),
            },
            &store,
        );
        assert!(filtered.ok);
        let old = dispatch(
            Request {
                version: PROTOCOL_VERSION,
                id: "test".into(),
                method: "events".into(),
                params: serde_json::json!({"after": "cur_00000000000000000001"}),
            },
            &store,
        );
        assert!(matches!(
            old.body,
            ResponseBody::Failure {
                error: ApiError {
                    code: ErrorCode::CursorTooOld,
                    ..
                },
                ..
            }
        ));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn media_resource_put_and_fetch_round_trip() {
        let dir = temp_dir("resource");
        let store = Arc::new(Mutex::new(Store::load(&dir).unwrap()));
        let put = dispatch(
            Request {
                version: PROTOCOL_VERSION,
                id: "put".into(),
                method: "media.resource.put".into(),
                params: serde_json::json!({"resource_id": "res-1", "bytes": [1, 2, 3]}),
            },
            &store,
        );
        assert!(put.ok);
        let fetch = dispatch(
            Request {
                version: PROTOCOL_VERSION,
                id: "fetch".into(),
                method: "media.resource.fetch".into(),
                params: serde_json::json!({"resource_id": "res-1"}),
            },
            &store,
        );
        assert!(fetch.ok);
        match fetch.body {
            ResponseBody::Success { result, .. } => {
                assert_eq!(result["bytes"], serde_json::json!([1, 2, 3]))
            }
            _ => panic!("resource fetch failed"),
        }
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
