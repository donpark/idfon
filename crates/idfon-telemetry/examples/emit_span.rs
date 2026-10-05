//! Emit one span to `IDFON_OTEL_ENDPOINT`, optionally parented to
//! `IDFON_OTEL_PARENT` (a W3C traceparent), then flush. Used by
//! `scripts/otel-e2e.sh` to prove the live export path against a real collector.
//!
//!   cargo run -p idfon-telemetry --features otlp --example emit_span

fn main() {
    let parent = std::env::var("IDFON_OTEL_PARENT").ok();
    idfon_telemetry::init("otel-e2e", "info");

    let span = tracing::info_span!("otel_e2e", trace = ?parent);
    idfon_telemetry::set_remote_parent(&span, parent.as_deref());
    {
        let _entered = span.enter();
        tracing::info!("emitted for the collector");
    }
    idfon_telemetry::flush();
}
