//! Thin `idfond` launcher. All daemon logic lives in the shared
//! `libiroh_c_ffi.dylib` (entry: `idfon_daemon_run`, implemented in
//! `native/vendor/iroh-c-ffi/src/daemon.rs` over the `idfon-daemon` crate);
//! this binary only parses arguments and calls into the dylib.

use std::ffi::CString;
use std::os::raw::c_char;

extern "C" {
    fn idfon_daemon_run(socket_path: *const c_char, data_dir: *const c_char, transport: *const c_char) -> i32;
}

const DEFAULT_SOCKET: &str = "/tmp/idfon/idfond.sock";
const DEFAULT_DATA_DIR: &str = "/tmp/idfon";

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let socket = argument(&args, "--socket").unwrap_or_else(|| DEFAULT_SOCKET.into());
    let data_dir = argument(&args, "--data-dir").unwrap_or_else(|| DEFAULT_DATA_DIR.into());
    let transport = argument(&args, "--transport");
    let socket_z = cstring(&socket, "--socket");
    let data_z = cstring(&data_dir, "--data-dir");
    let transport_z = transport.as_deref().map(|value| cstring(value, "--transport"));
    let code = unsafe {
        idfon_daemon_run(
            socket_z.as_ptr(),
            data_z.as_ptr(),
            transport_z.as_ref().map_or(std::ptr::null(), |value| value.as_ptr()),
        )
    };
    if code != 0 {
        // The daemon core prints the error itself before returning nonzero.
        std::process::exit(1);
    }
}

fn cstring(value: &str, flag: &str) -> CString {
    CString::new(value).unwrap_or_else(|_| {
        eprintln!("idfond: {flag} must not contain NUL bytes");
        std::process::exit(2);
    })
}

fn argument(args: &[String], name: &str) -> Option<String> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].clone())
}
