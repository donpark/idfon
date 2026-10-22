use std::path::PathBuf;

use once_cell::sync::Lazy;
use safer_ffi::{prelude::*, vec};

pub(crate) static TOKIO_EXECUTOR: Lazy<tokio::runtime::Runtime> =
    Lazy::new(|| tokio::runtime::Runtime::new().unwrap());

pub fn tokio_executor<F: std::future::Future>(future: F) -> F::Output {
    TOKIO_EXECUTOR.block_on(future)
}

/// Frees a Rust-allocated string.
#[ffi_export]
pub fn rust_free_string(string: char_p::Box) {
    drop(string)
}

/// Allocates a buffer managed by rust, given the initial size.
#[ffi_export]
pub fn rust_buffer_alloc(size: usize) -> vec::Vec<u8> {
    vec![0u8; size].into()
}

/// Returns the length of the buffer.
#[ffi_export]
pub fn rust_buffer_len(buf: &vec::Vec<u8>) -> usize {
    buf.len()
}

/// Frees the rust buffer.
#[ffi_export]
pub fn rust_buffer_free(buf: vec::Vec<u8>) {
    drop(buf);
}

/// Installs the tracing subscriber used for iroh/moq diagnostics.
///
/// Filter: `IDFON_LOG` / `RUST_LOG` / `IROH_C_LOG` (default info). Delegates
/// to the shared `idfon-telemetry` subscriber; a no-op when one is already set.
pub fn init_tracing(path: PathBuf) {
    eprintln!("[idfond] tracing init -> {:?}", path);
    idfon_telemetry::init_file("iroh-c-ffi", &path, "info");
}

/// Enables tracing for iroh (FFI entry, used by the apps).
#[ffi_export]
pub fn iroh_enable_tracing() {
    // iOS has no literal /tmp inside the app sandbox — open() fails and the
    // writer silently falls back to /dev/null. Use the sandbox tmp there.
    #[cfg(target_os = "ios")]
    let path = std::env::temp_dir().join(format!("idfon-{}.log", std::process::id()));
    #[cfg(not(target_os = "ios"))]
    let path = PathBuf::from(format!("/tmp/idfon-{}.log", std::process::id()));
    eprintln!("[idfond] tracing init -> {:?}", path);
    init_tracing(path);
}
