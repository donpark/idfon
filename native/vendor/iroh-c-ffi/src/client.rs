//! Thin C-ABI wrapper over the `nufon-client` IPC core (see
//! `crates/nufon-client`). Framing, socket-path resolution, connect-retry
//! policy, and response validation live in the core crate; this module only
//! converts C arguments, allocates the result buffer, and maps
//! `ClientError` to the historical NUFON_* codes:
//!   NUFON_ECONNECT  -> daemon_unavailable
//!   NUFON_EWRITE    -> daemon_write_failed
//!   NUFON_EREAD     -> daemon_read_failed
//!   NUFON_ETOOLARGE -> daemon_result_too_large
//!   NUFON_EINVALID  -> daemon_invalid_response

use std::ffi::CStr;
use std::os::raw::c_char;
use std::time::Duration;

use nufon_client::{Client, ClientError};

pub const NUFON_OK: i32 = 0;
pub const NUFON_EARG: i32 = -1; // null pointer argument
pub const NUFON_EREQUEST: i32 = -2; // request exceeds MAX_FRAME_BYTES
pub const NUFON_ECONNECT: i32 = -3; // daemon not reachable within timeout
pub const NUFON_EWRITE: i32 = -4;
pub const NUFON_EREAD: i32 = -5;
pub const NUFON_ETOOLARGE: i32 = -6; // response length exceeds MAX_FRAME_BYTES
pub const NUFON_EINVALID: i32 = -7; // response is not a valid protocol Response

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
    let path = nufon_client::socket_path_for(profile);
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
/// - On success returns `NUFON_OK`, writes a heap-allocated response body
///   (excluding the length prefix) to `*out`/`*out_len` — freed with
///   `nufon_client_result_free` — and writes 0/1 to `*ok` when non-null.
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
    if req_len > nufon_protocol::MAX_FRAME_BYTES {
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

    let mut client = match Client::connect_with_retry(path, Duration::from_millis(connect_timeout_ms as u64)) {
        Ok(client) => client,
        Err(ClientError::Connect(_)) => return NUFON_ECONNECT,
        Err(_) => return NUFON_EARG,
    };
    let response = match client.request(request) {
        Ok(response) => response,
        Err(error) => return error_code(&error),
    };
    if !ok.is_null() {
        unsafe { ok.write(u8::from(response.ok)) };
    }
    let boxed: Box<[u8]> = response.body.into_boxed_slice().into();
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

fn error_code(error: &ClientError) -> i32 {
    match error {
        ClientError::Connect(_) => NUFON_ECONNECT,
        ClientError::Write(_) => NUFON_EWRITE,
        ClientError::Read(_) => NUFON_EREAD,
        ClientError::FrameTooLarge => NUFON_ETOOLARGE,
        ClientError::InvalidResponse(_) => NUFON_EINVALID,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    fn unique_dir(name: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "nufon-ffi-{}-{name}",
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
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
    fn null_args_are_earg() {
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut ok: u8 = 255;
        let request = b"{}".to_vec();
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
    fn absent_daemon_is_econnect() {
        let dir = unique_dir("absent");
        let path = dir.join("s").to_str().unwrap().to_owned();
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut ok: u8 = 255;
        let request = b"{}".to_vec();
        assert_eq!(
            nufon_client_request(
                path.as_ptr().cast(),
                request.as_ptr(),
                request.len(),
                &mut out,
                &mut out_len,
                &mut ok,
                0
            ),
            NUFON_ECONNECT
        );
        assert!(out.is_null());
    }

    #[test]
    fn round_trip_through_ffi() {
        let dir = unique_dir("roundtrip");
        let path = dir.join("s");
        let listener = UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || {
            use std::io::{Read, Write};
            let (mut stream, _) = listener.accept().unwrap();
            let mut header = [0u8; 4];
            stream.read_exact(&mut header).unwrap();
            let mut request = vec![0u8; u32::from_be_bytes(header) as usize];
            stream.read_exact(&mut request).unwrap();
            let response =
                br#"{"version":1,"id":"t1","ok":true,"operation":"status","result":{}}"#.to_vec();
            stream.write_all(&(response.len() as u32).to_be_bytes()).unwrap();
            stream.write_all(&response).unwrap();
        });
        let path = path.to_str().unwrap().to_owned();
        let request = br#"{"version":1,"id":"t1","method":"status","params":{}}"#.to_vec();
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let mut ok: u8 = 255;
        assert_eq!(
            nufon_client_request(
                path.as_ptr().cast(),
                request.as_ptr(),
                request.len(),
                &mut out,
                &mut out_len,
                &mut ok,
                0
            ),
            NUFON_OK
        );
        assert_eq!(ok, 1);
        let body = unsafe { std::slice::from_raw_parts(out, out_len) }.to_vec();
        nufon_client_result_free(out, out_len);
        assert!(String::from_utf8(body).unwrap().contains("\"ok\":true"));
        server.join().unwrap();
    }
}
