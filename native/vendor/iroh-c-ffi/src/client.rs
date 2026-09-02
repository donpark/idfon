//! Nufond IPC client: 4-byte big-endian length-prefixed JSON frames over a
//! Unix socket. One request per connection, matching the daemon's
//! `read_frame`/`write_frame` loop (`crates/nufond/src/main.rs`).
//!
//! This is the single source of truth for client-side framing, socket-path
//! resolution, connect-retry policy, and response validation; the Zig host
//! shim (`native/src/iroh_ffi.zig`) only dispatches jobs and maps error
//! codes to its historical strings:
//!   NUFON_ECONNECT  -> daemon_unavailable
//!   NUFON_EWRITE    -> daemon_write_failed
//!   NUFON_EREAD     -> daemon_read_failed
//!   NUFON_ETOOLARGE -> daemon_result_too_large
//!   NUFON_EREQUEST  -> payload_too_large

use std::env;
use std::ffi::CStr;
use std::io::{Read, Write};
use std::os::raw::c_char;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use nufon_protocol::{Response, MAX_FRAME_BYTES};

pub const NUFON_OK: i32 = 0;
pub const NUFON_EARG: i32 = -1; // null pointer argument
pub const NUFON_EREQUEST: i32 = -2; // request exceeds MAX_FRAME_BYTES
pub const NUFON_ECONNECT: i32 = -3; // daemon not reachable within timeout
pub const NUFON_EWRITE: i32 = -4;
pub const NUFON_EREAD: i32 = -5;
pub const NUFON_ETOOLARGE: i32 = -6; // response length exceeds MAX_FRAME_BYTES
pub const NUFON_EINVALID: i32 = -7; // response is not a valid protocol Response

const DEFAULT_SOCKET: &str = "/tmp/nufon/nufond.sock";
const PROFILE_MAX_CHARS: usize = 64;
const CONNECT_POLL: Duration = Duration::from_millis(100);

/// Methods whose daemon responses are hand-encoded binary payloads instead of
/// a JSON `Response` (see the connection loop in `crates/nufond/src/main.rs`).
/// The historical Zig host accepted them via the `"ok":false` sniff, i.e. as
/// ok=true with raw bytes.
const BINARY_RESPONSE_METHODS: [&str; 3] = ["peers.compact", "identities.compact", "events.compact"];

fn request_expects_binary_response(request: &[u8]) -> bool {
    serde_json::from_slice::<nufon_protocol::Request>(request)
        .map(|request| BINARY_RESPONSE_METHODS.contains(&request.method.as_str()))
        .unwrap_or(false)
}

/// Resolves the daemon socket path for a profile, mirroring the historical
/// Zig `profilePaths` logic exactly:
/// - `profile` None/empty -> use the `NUFON_PROFILE` env var (if set)
/// - "default", empty, invalid characters, or longer than 64 chars (Zig
///   truncates at 64 before validating) -> fall back to the default path
/// - otherwise `/tmp/nufon-{profile}/nufond.sock`
fn socket_path_for(profile: Option<&[u8]>) -> String {
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

/// Writes the resolved daemon socket path (NUL-terminated) into `out`.
/// Returns the number of bytes written excluding the NUL, or `NUFON_EARG`
/// when `out` is null or the buffer is too small. A NULL or empty `profile`
/// reads the `NUFON_PROFILE` environment variable.
#[no_mangle]
pub extern "C" fn nufon_client_socket_path(profile: *const c_char, out: *mut u8, cap: usize) -> i32 {
    if out.is_null() {
        return NUFON_EARG;
    }
    let profile = if profile.is_null() {
        None
    } else {
        Some(unsafe { CStr::from_ptr(profile) }.to_bytes())
    };
    let path = socket_path_for(profile);
    if path.len() + 1 > cap {
        return NUFON_EARG;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(path.as_ptr(), out, path.len());
        out.add(path.len()).write(0);
    }
    path.len() as i32
}

/// Sends one request frame to the daemon and reads one response frame.
///
/// - `connect_timeout_ms` = 0 performs a single connect attempt; a positive
///   value polls every 100ms until the deadline (the Zig host calls with 0
///   first, launches the daemon, then retries with a 5000ms window).
/// - On success returns `NUFON_OK`, writes a heap-allocated JSON response
///   body (excluding the length prefix) to `*out`/`*out_len` — freed with
///   `nufon_client_result_free` — and writes 0/1 to `*ok` when non-null
///   (`1` = `Response.ok`).
/// - `req` is the already-encoded request JSON; it is forwarded verbatim
///   (the daemon validates it).
/// - Thread-safe: each call uses its own connection.
#[no_mangle]
pub extern "C" fn nufon_client_request(
    socket_path: *const c_char,
    req: *const u8,
    req_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    ok: *mut u8,
    connect_timeout_ms: u32,
) -> i32 {
    if socket_path.is_null() || out.is_null() || out_len.is_null() || (req.is_null() && req_len > 0)
    {
        return NUFON_EARG;
    }
    if req_len > MAX_FRAME_BYTES {
        return NUFON_EREQUEST;
    }
    let path = unsafe { CStr::from_ptr(socket_path) }.to_bytes();
    let path = match std::str::from_utf8(path) {
        Ok(path) => path,
        Err(_) => return NUFON_EARG,
    };
    let request = if req_len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(req, req_len) }
    };

    let Some(mut stream) = connect_with_retry(path, connect_timeout_ms) else {
        return NUFON_ECONNECT;
    };

    let mut frame = Vec::with_capacity(4 + request.len());
    frame.extend_from_slice(&(request.len() as u32).to_be_bytes());
    frame.extend_from_slice(request);
    if stream.write_all(&frame).is_err() {
        return NUFON_EWRITE;
    }

    let mut header = [0u8; 4];
    if stream.read_exact(&mut header).is_err() {
        return NUFON_EREAD;
    }
    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_FRAME_BYTES {
        return NUFON_ETOOLARGE;
    }
    let mut body = vec![0u8; length];
    if stream.read_exact(&mut body).is_err() {
        return NUFON_EREAD;
    }

    let is_binary = request_expects_binary_response(request);
    if !is_binary {
        let response: Response = match serde_json::from_slice(&body) {
            Ok(response) => response,
            Err(_) => return NUFON_EINVALID,
        };
        if !ok.is_null() {
            unsafe { ok.write(u8::from(response.ok)) };
        }
    } else if !ok.is_null() {
        // Binary compact payloads: daemon only sends these for methods that
        // cannot fail; the historical Zig host reported them as ok=true.
        unsafe { ok.write(1) };
    }
    let boxed: Box<[u8]> = body.into_boxed_slice().into();
    unsafe {
        *out_len = boxed.len();
        *out = Box::into_raw(boxed).cast();
    }
    NUFON_OK
}

/// Frees a response buffer returned by `nufon_client_request`. Passing a
/// null pointer is a no-op; `len` must be the value written to `*out_len`.
#[no_mangle]
pub extern "C" fn nufon_client_result_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    unsafe { drop(Box::from_raw(std::slice::from_raw_parts_mut(ptr, len))) };
}

fn connect_with_retry(path: &str, timeout_ms: u32) -> Option<UnixStream> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms as u64);
    loop {
        if let Ok(stream) = UnixStream::connect(path) {
            return Some(stream);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(CONNECT_POLL.min(deadline.saturating_duration_since(Instant::now())));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::sync::Mutex;
    use std::thread;

    /// Env-var mutation is process-global; serialize tests that touch it.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

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

    /// Spawns a stub daemon: serves `count` frames, applying `respond` to
    /// each received request. Returns (socket path, join handle).
    fn stub_server(name: &str, count: usize, respond: impl Fn(Vec<u8>) -> Vec<u8> + Send + 'static) -> (String, thread::JoinHandle<()>) {
        let dir = std::env::temp_dir().join(format!("nufon-client-test-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_file(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nufond.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let path = path.to_str().unwrap().to_owned();
        let handle = thread::spawn(move || {
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
        });
        (path, handle)
    }

    fn client_request(path: &str, request: &[u8], timeout_ms: u32) -> (i32, Option<Vec<u8>>, Option<bool>) {
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut ok: u8 = 255;
        let code = nufon_client_request(
            path.as_ptr().cast(),
            request.as_ptr(),
            request.len(),
            &mut out,
            &mut out_len,
            &mut ok,
            timeout_ms,
        );
        let body = (!out.is_null()).then(|| {
            let slice = unsafe { std::slice::from_raw_parts(out, out_len) }.to_vec();
            nufon_client_result_free(out, out_len);
            slice
        });
        (code, body, (ok != 255).then(|| ok == 1))
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
    fn socket_path_c_abi() {
        let mut buf = [0u8; 128];
        let written = nufon_client_socket_path(std::ptr::null(), buf.as_mut_ptr(), buf.len());
        assert!(written > 0);
        assert_eq!(&buf[..written as usize], b"/tmp/nufon/nufond.sock");
        // Buffer too small and null out are argument errors.
        assert_eq!(nufon_client_socket_path(std::ptr::null(), std::ptr::null_mut(), 0), NUFON_EARG);
        assert_eq!(nufon_client_socket_path(std::ptr::null(), buf.as_mut_ptr(), 4), NUFON_EARG);
    }

    #[test]
    fn round_trip_success() {
        let expected = success_json("t1", true);
        let (path, server) = stub_server("ok", 1, move |_| expected.clone());
        let (code, body, ok) = client_request(&path, &sample_request(), 0);
        assert_eq!(code, NUFON_OK);
        assert_eq!(ok, Some(true));
        assert_eq!(body.unwrap(), success_json("t1", true));
        server.join().unwrap();
    }

    #[test]
    fn failure_response_reports_ok_false() {
        let response = br#"{"version":1,"id":"t1","ok":false,"operation":"peer.show","error":{"code":"unknown_method","message":"no such peer","retryable":false}}"#.to_vec();
        let (path, server) = stub_server("fail", 1, move |_| response.clone());
        let (code, body, ok) = client_request(&path, &sample_request(), 0);
        assert_eq!(code, NUFON_OK);
        assert_eq!(ok, Some(false));
        assert!(body.unwrap().windows(14).any(|w| w == b"unknown_method"));
        server.join().unwrap();
    }

    #[test]
    fn connect_timeout_returns_econnect() {
        let dir = std::env::temp_dir().join(format!("nufon-client-test-{}-absent", std::process::id()));
        let path = dir.join("nufond.sock").to_str().unwrap().to_owned();
        let (code, body, _) = client_request(&path, &sample_request(), 0);
        assert_eq!(code, NUFON_ECONNECT);
        assert!(body.is_none());
    }

    #[test]
    fn connect_retry_eventually_succeeds() {
        let dir = std::env::temp_dir().join(format!("nufon-client-test-{}-late", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nufond.sock");
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
        let (code, body, _) = client_request(&path_str, &sample_request(), 2000);
        assert_eq!(code, NUFON_OK);
        assert!(body.is_some());
        binder.join().unwrap();
    }

    #[test]
    fn truncated_response_is_eread() {
        // Server declares a 100-byte body, then closes without sending it.
        let dir = std::env::temp_dir().join(format!("nufon-client-test-{}-truncated", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nufond.sock");
        let path_str = path.to_str().unwrap().to_owned();
        let mut listener = UnixListener::bind(&path).unwrap(); // bind before client connects
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut header = [0u8; 4];
            stream.read_exact(&mut header).unwrap();
            let mut request = vec![0u8; u32::from_be_bytes(header) as usize];
            stream.read_exact(&mut request).unwrap();
            stream.write_all(&100u32.to_be_bytes()).unwrap();
            drop(stream); // close before delivering the body
        });
        let (code, body, _) = client_request(&path_str, &sample_request(), 0);
        assert_eq!(code, NUFON_EREAD);
        assert!(body.is_none());
        server.join().unwrap();
    }

    #[test]
    fn empty_response_is_einvalid() {
        let (path, server) = stub_server("empty", 1, |_| Vec::new());
        let (code, body, _) = client_request(&path, &sample_request(), 0);
        assert_eq!(code, NUFON_EINVALID);
        assert!(body.is_none());
        server.join().unwrap();
    }

    #[test]
    fn oversized_response_is_etoolarge() {
        // Server declares a body larger than MAX_FRAME_BYTES, then closes.
        let dir = std::env::temp_dir().join(format!("nufon-client-test-{}-oversized", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nufond.sock");
        let path_str = path.to_str().unwrap().to_owned();
        let mut listener = UnixListener::bind(&path).unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut header = [0u8; 4];
            stream.read_exact(&mut header).unwrap();
            let mut request = vec![0u8; u32::from_be_bytes(header) as usize];
            stream.read_exact(&mut request).unwrap();
            stream.write_all(&((MAX_FRAME_BYTES as u32) + 1).to_be_bytes()).unwrap();
            drop(stream);
        });
        let (code, body, _) = client_request(&path_str, &sample_request(), 0);
        assert_eq!(code, NUFON_ETOOLARGE);
        assert!(body.is_none());
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
        let (path, server) = stub_server("binary", 1, move |_| value.clone());
        let request = br#"{"version":1,"id":"g1","method":"identities.compact","params":{}}"#.to_vec();
        let (code, body, ok) = client_request(&path, &request, 0);
        assert_eq!(code, NUFON_OK);
        assert_eq!(ok, Some(true));
        assert_eq!(body.unwrap(), expected);
        server.join().unwrap();
    }

    #[test]
    fn malformed_response_is_einvalid() {
        let (path, server) = stub_server("garbage", 1, |_| b"not json at all".to_vec());
        let (code, body, _) = client_request(&path, &sample_request(), 0);
        assert_eq!(code, NUFON_EINVALID);
        assert!(body.is_none());
        server.join().unwrap();
    }

    #[test]
    fn oversized_request_is_erequest() {
        let big = vec![b'x'; MAX_FRAME_BYTES + 1];
        let (code, _, _) = client_request("/tmp/nufon/nufond.sock", &big, 0);
        assert_eq!(code, NUFON_EREQUEST);
    }

    #[test]
    fn null_args_are_earg() {
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut ok: u8 = 255;
        let request = sample_request();
        assert_eq!(
            nufon_client_request(
                std::ptr::null(),
                request.as_ptr(),
                request.len(),
                &mut out,
                &mut out_len,
                &mut ok,
                0
            ),
            NUFON_EARG
        );
        assert_eq!(
            nufon_client_request(b"/tmp/x\0".as_ptr().cast(), std::ptr::null(), 5, &mut out, &mut out_len, &mut ok, 0),
            NUFON_EARG
        );
    }

    #[test]
    fn concurrent_requests_interleave() {
        let (path, server) = stub_server("concurrent", 4, move |request| {
            let request: serde_json::Value = serde_json::from_slice(&request).unwrap();
            let id = request["id"].as_str().unwrap().to_owned();
            success_json(&id, true)
        });
        let handles: Vec<_> = (0..4)
            .map(|i| {
                let path = path.clone();
                thread::spawn(move || {
                    let request = format!(r#"{{"version":1,"id":"c{i}","method":"status","params":{{}}}}"#).into_bytes();
                    let (code, body, ok) = client_request(&path, &request, 0);
                    assert_eq!(code, NUFON_OK);
                    assert_eq!(ok, Some(true));
                    let body = body.unwrap();
                    assert!(String::from_utf8(body).unwrap().contains(&format!("\"id\":\"c{i}\"")));
                })
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }
        server.join().unwrap();
    }
}
