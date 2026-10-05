//! One process-wide tracing subscriber, shared by every idfon entry point.
//!
//! The point of P0 in `docs/observability.md`: instead of each process
//! inventing its own logger, they all call [`init`] / [`init_file`], which
//! installs the same subscriber exactly once. First call wins; a later call is
//! a no-op, so an embedding app can install the file sink before starting the
//! daemon and the daemon's own call does nothing.
//!
//! Filter precedence (first set wins): `IDFON_LOG`, `RUST_LOG`, `IROH_C_LOG`,
//! then the caller's default. `IROH_C_LOG` is kept for the app/FFI path that
//! has always used it.
//!
//! Sink: [`init`] appends to `IDFON_LOG_FILE` when set, otherwise stderr;
//! [`init_file`] always appends to the given path.

use std::path::{Path, PathBuf};

use tracing_subscriber::{prelude::*, EnvFilter};

/// Install the shared subscriber if none is set. Returns nothing on purpose:
/// callers must never fail startup because telemetry could not initialise.
pub fn init(service: &str, default_filter: &str) {
    match std::env::var_os("IDFON_LOG_FILE") {
        Some(path) => {
            install(service, Some(PathBuf::from(path)), default_filter);
        }
        None => {
            install(service, None, default_filter);
        }
    }
}

/// Like [`init`], but always appends to `path` (the FFI/app path uses a
/// per-process `/tmp/idfon-<pid>.log`).
pub fn init_file(service: &str, path: &Path, default_filter: &str) {
    install(service, Some(path.to_path_buf()), default_filter);
}

fn filter(default_filter: &str) -> EnvFilter {
    EnvFilter::try_from_env("IDFON_LOG")
        .or_else(|_| EnvFilter::try_from_env("RUST_LOG"))
        .or_else(|_| EnvFilter::try_from_env("IROH_C_LOG"))
        .unwrap_or_else(|_| EnvFilter::new(default_filter))
}

/// Installs the subscriber; `true` when this call won. Idempotent.
fn install(service: &str, path: Option<PathBuf>, default_filter: &str) -> bool {
    let filter = filter(default_filter);
    let layer = tracing_subscriber::fmt::layer()
        .with_ansi(false)
        .with_line_number(true);
    let installed = match path {
        Some(path) => {
            let writer = move || {
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&path)
                    .unwrap_or_else(|_| {
                        std::fs::File::create("/dev/null").expect("/dev/null unavailable")
                    })
            };
            tracing_subscriber::registry()
                .with(filter)
                .with(layer.with_writer(writer))
                .try_init()
                .is_ok()
        }
        None => tracing_subscriber::registry()
            .with(filter)
            .with(layer.with_writer(std::io::stderr))
            .try_init()
            .is_ok(),
    };
    if installed {
        tracing::info!(service, pid = std::process::id(), "telemetry initialised");
    }
    installed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_is_first_wins() {
        // One process-wide subscriber; the second install must be a no-op.
        assert!(install("test", None, "info"));
        assert!(!install("test", None, "info"));
    }
}
