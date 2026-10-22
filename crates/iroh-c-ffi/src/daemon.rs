//! Thin C-ABI wrapper over the `idfon-daemon` core. The thin `idfond`
//! binary (`crates/idfond`) links this dylib and calls [`idfon_daemon_run`],
//! which blocks until the daemon exits (ctrl_c or error). All daemon logic
//! lives in `crates/idfon-daemon`; this module only converts C arguments.

use std::ffi::CStr;
use std::os::raw::c_char;

pub const IDFON_DAEMON_OK: i32 = 0;
pub const IDFON_DAEMON_EARG: i32 = -1; // null or non-UTF-8 argument
pub const IDFON_DAEMON_EFAILED: i32 = -2; // daemon exited with an error (already printed to stderr)

/// Runs the daemon on the calling thread until it exits. `socket_path` and
/// `data_dir` must be non-null; `transport` may be NULL for the default
/// ("iroh"; the only other valid value is "fake"). Returns
/// `IDFON_DAEMON_OK` after a clean ctrl_c shutdown, or a negative code with
/// the error already printed to stderr.
#[no_mangle]
pub extern "C" fn idfon_daemon_run(
    socket_path: *const c_char,
    data_dir: *const c_char,
    transport: *const c_char,
) -> i32 {
    let to_option = |pointer: *const c_char| -> Option<String> {
        if pointer.is_null() {
            return None;
        }
        unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .ok()
            .map(|value| value.to_owned())
    };
    let (Some(socket), Some(data_dir)) = (to_option(socket_path), to_option(data_dir)) else {
        return IDFON_DAEMON_EARG;
    };
    let config = idfon_daemon::DaemonConfig {
        socket: socket.into(),
        data_dir: data_dir.into(),
        transport: to_option(transport),
        idle_exit: None,
    };
    match idfon_daemon::run_blocking(config) {
        Ok(()) => IDFON_DAEMON_OK,
        Err(error) => {
            eprintln!("idfond: {error}");
            IDFON_DAEMON_EFAILED
        }
    }
}

/// One request/response round-trip into the embedded feature set: the same
/// functions the daemon packaging serves over the RPC bridge
/// (`idfon_client_request`), called directly in-process — the embedder (the
/// iOS app) links this crate, so there is no socket and no separate
/// lifecycle. Result conventions mirror `idfon_client_request`: `IDFON_OK`
/// plus a heap buffer freed with `idfon_client_result_free`; `ok` (optional)
/// receives 1/0 for response.ok. `IDFON_ECONNECT` means the feature set has
/// not finished starting — retry, exactly like the bridge's connect error.
#[no_mangle]
pub extern "C" fn idfon_request(
    req: *const u8,
    req_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    ok: *mut u8,
) -> i32 {
    use crate::client::{
        IDFON_EARG, IDFON_ECONNECT, IDFON_EINVALID, IDFON_EREQUEST, IDFON_ETOOLARGE, IDFON_OK,
    };

    if out.is_null() || out_len.is_null() || (req.is_null() && req_len > 0) {
        return IDFON_EARG;
    }
    if req_len > idfon_protocol::MAX_FRAME_BYTES {
        return IDFON_EREQUEST;
    }
    let request = if req_len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(req, req_len) }
    };
    let (body, response_ok) = match idfon_daemon::request_json(request) {
        Ok(result) => result,
        Err(error) if error.kind() == std::io::ErrorKind::NotConnected => return IDFON_ECONNECT,
        Err(error) if error.kind() == std::io::ErrorKind::InvalidData => return IDFON_ETOOLARGE,
        Err(_) => return IDFON_EINVALID,
    };
    if !ok.is_null() {
        unsafe { ok.write(u8::from(response_ok)) };
    }
    let boxed: Box<[u8]> = body.into_boxed_slice();
    unsafe {
        *out_len = boxed.len();
        *out = Box::into_raw(boxed).cast();
    }
    IDFON_OK
}
