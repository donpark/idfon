//! End-to-end smoke test: with the `otlp` feature and an endpoint set, a
//! `tracing` span is exported as an OTLP/HTTP POST. We stand up a throwaway TCP
//! listener as the "collector" and assert a request lands.
//!
//! Compiled only with `--features otlp` (the default build has no exporter).
#![cfg(feature = "otlp")]

use std::io::{ErrorKind, Read, Write};
use std::net::TcpListener;
use std::sync::mpsc;
use std::time::{Duration, Instant};

#[test]
fn exports_a_span_over_otlp_http() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        // The exporter may open more than one connection (retries, pool); accept
        // until we see the export or the deadline passes.
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            listener.set_nonblocking(true).ok();
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream.set_read_timeout(Some(Duration::from_secs(2))).ok();
                    let mut buf = vec![0u8; 16384];
                    let read = stream.read(&mut buf).unwrap_or(0);
                    let request = String::from_utf8_lossy(&buf[..read]).to_string();
                    let _ = stream.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n");
                    if request.starts_with("POST /v1/traces") {
                        let _ = tx.send(request);
                        return;
                    }
                }
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(_) => break,
            }
        }
        let _ = tx.send(String::new());
    });

    std::env::set_var("IDFON_OTEL_ENDPOINT", format!("http://{addr}/v1/traces"));
    std::env::set_var("IDFON_OTEL_SAMPLE_RATIO", "1.0");
    idfon_telemetry::init("otlp-smoke", "info");

    {
        let span = tracing::info_span!("smoke_span");
        let _entered = span.enter();
        tracing::info!("inside the span");
    }
    // Force the batch out now instead of waiting for the scheduled delay.
    idfon_telemetry::flush();

    let request = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("collector thread did not report");
    assert!(
        request.starts_with("POST /v1/traces"),
        "collector received no OTLP export (got: {:?})",
        &request[..request.len().min(120)]
    );
}
