use std::{fs::OpenOptions, path::PathBuf};

use once_cell::sync::Lazy;
use safer_ffi::{prelude::*, vec};
use tracing_subscriber::{prelude::*, EnvFilter};

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

/// Enables tracing for iroh.
///
/// Log level can be controlled using the env variable `IROH_C_LOG`.
#[ffi_export]
pub fn iroh_enable_tracing() {
    // iOS has no literal /tmp inside the app sandbox — open() fails and the
    // writer silently falls back to /dev/null. Use the sandbox tmp there.
    #[cfg(target_os = "ios")]
    let path = std::env::temp_dir().join(format!("idfon-{}.log", std::process::id()));
    #[cfg(not(target_os = "ios"))]
    let path = PathBuf::from(format!("/tmp/idfon-{}.log", std::process::id()));
    eprintln!("[idfond] tracing init -> {:?}", path);
    let writer = move || {
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .unwrap_or_else(|_| std::fs::File::create("/dev/null").expect("/dev/null unavailable"))
    };
    let _ = tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_writer(writer)
                .event_format(tracing_subscriber::fmt::format().with_line_number(true)),
        )
        .with(EnvFilter::try_from_env("IROH_C_LOG").unwrap_or_else(|_| EnvFilter::new("info")))
        .try_init();
}
