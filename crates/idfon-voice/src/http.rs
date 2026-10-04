//! Small HTTP helpers shared by the cloud provider adapters.
#![cfg(feature = "gateway")]

/// Bridge a sync trait method to an async HTTP client. The holder runs a
/// multi-thread runtime, so `block_in_place` is safe; outside a runtime
/// (tests) we build a small one.
pub(crate) fn block_on<F: std::future::Future>(future: F) -> F::Output {
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => tokio::task::block_in_place(|| handle.block_on(future)),
        Err(_) => tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build provider runtime")
            .block_on(future),
    }
}

/// Cap an error body so a giant HTML error page cannot flood the logs.
pub(crate) fn truncate(text: &str) -> String {
    const MAX: usize = 200;
    if text.len() <= MAX {
        return text.to_string();
    }
    format!("{}…", &text[..MAX])
}
