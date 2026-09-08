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
        unsafe { CStr::from_ptr(pointer) }.to_str().ok().map(|value| value.to_owned())
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
