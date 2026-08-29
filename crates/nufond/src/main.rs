#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::{
    io,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

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

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct Store {
    identities: Vec<Identity>,
    peers: Vec<nufon_protocol::Peer>,
}

impl Store {
    fn load(data_dir: &Path) -> io::Result<Self> {
        let path = data_dir.join("state.json");
        match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(io::Error::other),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let store = Self {
                    identities: vec![Identity {
                        id: "default".into(),
                        name: "Default".into(),
                        endpoint_id: None,
                        active: true,
                    }],
                    peers: Vec::new(),
                };
                store.save(data_dir)?;
                Ok(store)
            }
            Err(error) => Err(error),
        }
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
    let _data_lock = DataLock::acquire(&data_dir)?;
    let store = Arc::new(Mutex::new(Store::load(&data_dir)?));
    prepare_socket(&socket)?;
    if let Some(parent) = socket.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let listener = UnixListener::bind(&socket)?;
    #[cfg(unix)]
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    let _cleanup = SocketCleanup(socket.clone());

    tokio::select! {
        result = accept_loop(listener, store) => result,
        result = tokio::signal::ctrl_c() => result.map_err(io::Error::other),
    }
}

async fn accept_loop(listener: UnixListener, store: Arc<Mutex<Store>>) -> io::Result<()> {
    loop {
        let (stream, _) = listener.accept().await?;
        let store = Arc::clone(&store);
        tokio::spawn(async move {
            if let Err(error) = serve(stream, store).await {
                eprintln!("nufond client error: {error}");
            }
        });
    }
}

async fn serve(mut stream: UnixStream, store: Arc<Mutex<Store>>) -> io::Result<()> {
    loop {
        let Some(frame) = read_frame(&mut stream).await? else {
            return Ok(());
        };
        let response = match serde_json::from_slice::<Request>(&frame) {
            Ok(request) => dispatch(request, &store),
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
        assert!(dir.join("state.json").is_file());

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
