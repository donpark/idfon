//! Nufond IPC client: 4-byte big-endian length-prefixed JSON frames over a
//! Unix socket. One or more request/response exchanges per connection,
//! matching the daemon's `read_frame`/`write_frame` loop
//! (`crates/nufond/src/main.rs`).
//!
//! This is the single source of truth for client-side framing, socket-path
//! resolution, connect-retry policy, and response validation. Consumers:
//! the FFI wrapper in `native/vendor/iroh-c-ffi/src/client.rs` (used by the
//! Zig app host) and the `nufon` CLI.

use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use nufon_protocol::{Request, Response, MAX_FRAME_BYTES};

pub const DEFAULT_SOCKET: &str = "/tmp/nufon/nufond.sock";
const PROFILE_MAX_CHARS: usize = 64;
const CONNECT_POLL: Duration = Duration::from_millis(100);

/// Methods whose daemon responses are hand-encoded binary payloads instead of
/// a JSON `Response` (see the connection loop in `crates/nufond/src/main.rs`).
/// The historical Zig host accepted them via the `"ok":false` sniff, i.e. as
/// ok=true with raw bytes.
const BINARY_RESPONSE_METHODS: [&str; 3] = ["peers.compact", "identities.compact", "events.compact"];

#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("daemon unavailable: {0}")]
    Connect(#[source] std::io::Error),
    #[error("daemon write failed: {0}")]
    Write(#[source] std::io::Error),
    #[error("daemon read failed: {0}")]
    Read(#[source] std::io::Error),
    #[error("response frame too large")]
    FrameTooLarge,
    #[error("invalid daemon response: {0}")]
    InvalidResponse(#[from] serde_json::Error),
}

/// One daemon response: `ok` plus the raw body bytes. JSON responses are
/// validated against the protocol `Response` shape before being returned;
/// `*.compact` methods return binary payloads verbatim with `ok = true`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientResponse {
    pub ok: bool,
    pub body: Vec<u8>,
}

impl ClientResponse {
    /// Deserializes a JSON response body (binary payloads error here).
    pub fn json(&self) -> Result<Response, serde_json::Error> {
        serde_json::from_slice(&self.body)
    }
}

pub struct Client {
    stream: UnixStream,
}

impl Client {
    /// Single connect attempt.
    pub fn connect(path: &str) -> Result<Client, ClientError> {
        UnixStream::connect(path).map(|stream| Client { stream }).map_err(ClientError::Connect)
    }

    /// Connects, polling every 100ms until `timeout` elapses. A zero timeout
    /// performs a single attempt (callers launch the daemon on failure and
    /// retry with a positive window).
    pub fn connect_with_retry(path: &str, timeout: Duration) -> Result<Client, ClientError> {
        let deadline = Instant::now() + timeout;
        loop {
            match UnixStream::connect(path) {
                Ok(stream) => return Ok(Client { stream }),
                Err(error) if Instant::now() >= deadline => return Err(ClientError::Connect(error)),
                Err(_) => {}
            }
            std::thread::sleep(CONNECT_POLL.min(deadline.saturating_duration_since(Instant::now())));
        }
    }

    /// Sends one request frame and reads one response frame on this
    /// connection. The request is forwarded verbatim; the daemon validates it.
    pub fn round_trip(&mut self, request: &[u8]) -> Result<ClientResponse, ClientError> {
        write_frame(&mut self.stream, request).map_err(ClientError::Write)?;
        self.next_response()
    }

    /// Reads one response frame without sending a request (daemon-push flows,
    /// e.g. `events --follow`; those push JSON `Response` frames).
    pub fn next_response(&mut self) -> Result<ClientResponse, ClientError> {
        let body = read_frame(&mut self.stream)?;
        parse_response(body)
    }

    /// `round_trip` with the response kind chosen from the request's method:
    /// the `*.compact` methods return binary payloads (ok = true), everything
    /// else must be a valid protocol `Response`.
    pub fn request(&mut self, request: &[u8]) -> Result<ClientResponse, ClientError> {
        write_frame(&mut self.stream, request).map_err(ClientError::Write)?;
        let body = read_frame(&mut self.stream)?;
        if request_expects_binary_response(request) {
            // Binary compact payloads: the daemon only sends these for
            // methods that cannot fail.
            return Ok(ClientResponse { ok: true, body });
        }
        parse_response(body)
    }
}

fn write_frame(stream: &mut UnixStream, payload: &[u8]) -> std::io::Result<()> {
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(payload);
    stream.write_all(&frame)
}

fn read_frame(stream: &mut UnixStream) -> Result<Vec<u8>, ClientError> {
    let mut header = [0u8; 4];
    stream.read_exact(&mut header).map_err(ClientError::Read)?;
    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_FRAME_BYTES {
        return Err(ClientError::FrameTooLarge);
    }
    let mut body = vec![0u8; length];
    stream.read_exact(&mut body).map_err(ClientError::Read)?;
    Ok(body)
}

fn parse_response(body: Vec<u8>) -> Result<ClientResponse, ClientError> {
    let response: Response = serde_json::from_slice(&body).map_err(ClientError::InvalidResponse)?;
    Ok(ClientResponse { ok: response.ok, body })
}

fn request_expects_binary_response(request: &[u8]) -> bool {
    serde_json::from_slice::<Request>(request)
        .map(|request| BINARY_RESPONSE_METHODS.contains(&request.method.as_str()))
        .unwrap_or(false)
}

/// Resolves the daemon socket path for a profile, mirroring the historical
/// Zig `profilePaths` logic exactly:
/// - `profile` None/empty -> use the `NUFON_PROFILE` env var (if set)
/// - "default", empty, invalid characters, or longer than 64 chars (Zig
///   truncates at 64 before validating) -> fall back to the default path
/// - otherwise `/tmp/nufon-{profile}/nufond.sock`
pub fn socket_path_for(profile: Option<&[u8]>) -> String {
    let raw: Vec<u8> = match profile {
        Some(bytes) if !bytes.is_empty() => bytes.to_vec(),
        _ => match env::var_os("NUFON_PROFILE") {
            Some(value) if !value.is_empty() => value.as_encoded_bytes().to_vec(),
            _ => return DEFAULT_SOCKET.into(),
        },
    };
    // Mirror Zig: the profile scan stops after PROFILE_MAX_CHARS bytes.
    let bytes = &raw[..raw.len().min(PROFILE_MAX_CHARS)];
    if bytes == b"default" {
        return DEFAULT_SOCKET.into();
    }
    let valid = bytes
        .iter()
        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-' || *byte == b'_');
    if !valid || bytes.is_empty() {
        return DEFAULT_SOCKET.into();
    }
    let profile = String::from_utf8(bytes.to_vec()).expect("validated ASCII");
    format!("/tmp/nufon-{profile}/nufond.sock")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;
    use std::os::unix::net::UnixListener;
    use std::sync::Mutex;
    use std::thread;
    use std::time::SystemTime;

    /// Env-var mutation is process-global; serialize tests that touch it.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    /// Unique short suffix (socket paths must stay under SUN_LEN ~104).
    fn unique_id() -> u32 {
        use std::sync::atomic::{AtomicU32, Ordering};
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        COUNTER.fetch_add(1, Ordering::Relaxed)
    }

    fn temp_socket(name: &str) -> (String, UnixListener) {
        let dir = std::env::temp_dir().join(format!("nufon-c-{}-{name}", unique_id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s");
        let listener = UnixListener::bind(&path).unwrap();
        (path.to_str().unwrap().to_owned(), listener)
    }

    fn success_json(id: &str, ok: bool) -> Vec<u8> {
        format!(
            concat!(
                "{{\"version\":1,\"id\":\"{id}\",\"ok\":{ok},",
                "\"operation\":\"status\",\"result\":{{\"daemon\":\"up\"}}}}"
            ),
            id = id,
            ok = ok
        )
        .into_bytes()
    }

    /// Serves `count` frames, applying `respond` to each received request.
    fn serve(listener: UnixListener, count: usize, respond: impl Fn(Vec<u8>) -> Vec<u8> + Send + 'static) -> thread::JoinHandle<()> {
        thread::spawn(move || {
            for _ in 0..count {
                let (mut stream, _) = listener.accept().unwrap();
                let mut header = [0u8; 4];
                if stream.read_exact(&mut header).is_err() {
                    break;
                }
                let length = u32::from_be_bytes(header) as usize;
                let mut request = vec![0u8; length];
                if stream.read_exact(&mut request).is_err() {
                    break;
                }
                let response = respond(request);
                let _ = stream.write_all(&(response.len() as u32).to_be_bytes());
                let _ = stream.write_all(&response);
            }
        })
    }

    fn sample_request() -> Vec<u8> {
        br#"{"version":1,"id":"t1","method":"status","params":{}}"#.to_vec()
    }

    #[test]
    fn socket_path_table() {
        let _guard = ENV_LOCK.lock().unwrap();
        env::remove_var("NUFON_PROFILE");
        assert_eq!(socket_path_for(None), "/tmp/nufon/nufond.sock");
        assert_eq!(socket_path_for(Some(b"default")), "/tmp/nufon/nufond.sock");
        assert_eq!(socket_path_for(Some(b"")), "/tmp/nufon/nufond.sock");
        assert_eq!(socket_path_for(Some(b"alice")), "/tmp/nufon-alice/nufond.sock");
        assert_eq!(socket_path_for(Some(b"a-b_9")), "/tmp/nufon-a-b_9/nufond.sock");
        // Invalid characters, invalid UTF-8, and >64 chars fall back
        // (mirroring Zig's truncate-then-validate).
        assert_eq!(socket_path_for(Some(b"../evil")), "/tmp/nufon/nufond.sock");
        assert_eq!(socket_path_for(Some(b"sp ace")), "/tmp/nufon/nufond.sock");
        assert_eq!(socket_path_for(Some(&[0xff, b'x'])), "/tmp/nufon/nufond.sock");
        let long = vec![b'a'; 70];
        assert_eq!(socket_path_for(Some(&long)), format!("/tmp/nufon-{}/nufond.sock", "a".repeat(64)));
        assert_eq!(socket_path_for(Some(&vec![b'a'; 64])), format!("/tmp/nufon-{}/nufond.sock", "a".repeat(64)));

        env::set_var("NUFON_PROFILE", "bob");
        assert_eq!(socket_path_for(None), "/tmp/nufon-bob/nufond.sock");
        // Explicit profile beats the env var.
        assert_eq!(socket_path_for(Some(b"carol")), "/tmp/nufon-carol/nufond.sock");
        env::remove_var("NUFON_PROFILE");
    }

    #[test]
    fn round_trip_success() {
        let expected = success_json("t1", true);
        let (path, listener) = temp_socket("ok");
        let server = serve(listener, 1, move |_| expected.clone());
        let mut client = Client::connect(&path).unwrap();
        let response = client.round_trip(&sample_request()).unwrap();
        assert!(response.ok);
        assert_eq!(response.body, success_json("t1", true));
        server.join().unwrap();
    }

    #[test]
    fn failure_response_reports_ok_false() {
        let response = br#"{"version":1,"id":"t1","ok":false,"operation":"peer.show","error":{"code":"unknown_method","message":"no such peer","retryable":false}}"#.to_vec();
        let (path, listener) = temp_socket("fail");
        let server = serve(listener, 1, move |_| response.clone());
        let mut client = Client::connect(&path).unwrap();
        let response = client.round_trip(&sample_request()).unwrap();
        assert!(!response.ok);
        assert!(response.body.windows(14).any(|w| w == b"unknown_method"));
        server.join().unwrap();
    }

    #[test]
    fn connect_timeout_returns_connect_error() {
        let (path, _listener) = temp_socket("absent");
        drop(_listener); // nobody accepts on this socket
        let result = Client::connect_with_retry(&path, Duration::ZERO);
        assert!(matches!(result, Err(ClientError::Connect(_))));
    }

    #[test]
    fn connect_retry_eventually_succeeds() {
        let dir = std::env::temp_dir().join(format!("nufon-c-{}-late", unique_id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s");
        let path_str = path.to_str().unwrap().to_owned();
        // Daemon appears after 150ms; a 2000ms window must find it.
        let binder = thread::spawn(move || {
            thread::sleep(Duration::from_millis(150));
            let listener = UnixListener::bind(&path).unwrap();
            let (mut stream, _) = listener.accept().unwrap();
            let mut header = [0u8; 4];
            stream.read_exact(&mut header).unwrap();
            let mut request = vec![0u8; u32::from_be_bytes(header) as usize];
            stream.read_exact(&mut request).unwrap();
            let response = success_json("t1", true);
            stream.write_all(&(response.len() as u32).to_be_bytes()).unwrap();
            stream.write_all(&response).unwrap();
        });
        let mut client = Client::connect_with_retry(&path_str, Duration::from_millis(2000)).unwrap();
        let response = client.round_trip(&sample_request()).unwrap();
        assert!(response.ok);
        binder.join().unwrap();
    }

    #[test]
    fn truncated_response_is_read_error() {
        // Server declares a 100-byte body, then closes without sending it.
        let (path, listener) = temp_socket("truncated");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut header = [0u8; 4];
            stream.read_exact(&mut header).unwrap();
            let mut request = vec![0u8; u32::from_be_bytes(header) as usize];
            stream.read_exact(&mut request).unwrap();
            stream.write_all(&100u32.to_be_bytes()).unwrap();
            drop(stream); // close before delivering the body
        });
        let mut client = Client::connect(&path).unwrap();
        let result = client.round_trip(&sample_request());
        assert!(matches!(result, Err(ClientError::Read(_))));
        server.join().unwrap();
    }

    #[test]
    fn oversized_response_is_frame_too_large() {
        let (path, listener) = temp_socket("oversized");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut header = [0u8; 4];
            stream.read_exact(&mut header).unwrap();
            let mut request = vec![0u8; u32::from_be_bytes(header) as usize];
            stream.read_exact(&mut request).unwrap();
            // Declare a body larger than MAX_FRAME_BYTES, then close.
            stream.write_all(&((MAX_FRAME_BYTES as u32) + 1).to_be_bytes()).unwrap();
            drop(stream);
        });
        let mut client = Client::connect(&path).unwrap();
        let result = client.round_trip(&sample_request());
        assert!(matches!(result, Err(ClientError::FrameTooLarge)));
        server.join().unwrap();
    }

    #[test]
    fn malformed_response_is_invalid() {
        let (path, listener) = temp_socket("garbage");
        let server = serve(listener, 1, |_| b"not json at all".to_vec());
        let mut client = Client::connect(&path).unwrap();
        let result = client.round_trip(&sample_request());
        assert!(matches!(result, Err(ClientError::InvalidResponse(_))));
        server.join().unwrap();
    }

    #[test]
    fn empty_response_is_invalid() {
        let (path, listener) = temp_socket("empty");
        let server = serve(listener, 1, |_| Vec::new());
        let mut client = Client::connect(&path).unwrap();
        let result = client.round_trip(&sample_request());
        assert!(matches!(result, Err(ClientError::InvalidResponse(_))));
        server.join().unwrap();
    }

    #[test]
    fn binary_compact_responses_pass_through() {
        // identities.compact returns a raw binary payload (u16 count + names).
        let value: Vec<u8> = [0x00u8, 0x03, 0x00, 0x07].iter().copied()
            .chain(b"Default".iter().copied())
            .chain([0x00, 0x00, 0x03].iter().copied())
            .chain(b"Bob".iter().copied())
            .chain([0x00, 0x00, 0x05].iter().copied())
            .chain(b"Alice".iter().copied())
            .chain([0x01].iter().copied())
            .collect();
        let expected = value.clone();
        let (path, listener) = temp_socket("binary");
        let server = serve(listener, 1, move |_| value.clone());
        let mut client = Client::connect(&path).unwrap();
        let request = br#"{"version":1,"id":"g1","method":"identities.compact","params":{}}"#.to_vec();
        let response = client.request(&request).unwrap();
        assert!(response.ok);
        assert_eq!(response.body, expected);
        server.join().unwrap();
    }

    #[test]
    fn concurrent_requests_interleave() {
        let (path, listener) = temp_socket("concurrent");
        let server = serve(listener, 4, move |request| {
            let request: serde_json::Value = serde_json::from_slice(&request).unwrap();
            let id = request["id"].as_str().unwrap().to_owned();
            success_json(&id, true)
        });
        let handles: Vec<_> = (0..4)
            .map(|i| {
                let path = path.clone();
                thread::spawn(move || {
                    let request = format!(r#"{{"version":1,"id":"c{i}","method":"status","params":{{}}}}"#).into_bytes();
                    let mut client = Client::connect(&path).unwrap();
                    let response = client.round_trip(&request).unwrap();
                    assert!(response.ok);
                    assert!(String::from_utf8(response.body).unwrap().contains(&format!("\"id\":\"c{i}\"")));
                })
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }
        server.join().unwrap();
    }
}
