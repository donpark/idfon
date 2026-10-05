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
//!
//! **OTLP (P2).** With the `otlp` feature, setting `IDFON_OTEL_ENDPOINT` adds a
//! span exporter (OTLP/HTTP, batch) and samples at `IDFON_OTEL_SAMPLE_RATIO`
//! (default 0.1). When unset the layer is inert. The daemon dylib (shared with
//! iOS) deliberately does not enable the feature; only the standalone holder,
//! MCP, and CLI binaries do.

use std::io::Write;
use std::path::{Path, PathBuf};

use tracing_subscriber::{prelude::*, EnvFilter};

enum Sink {
    Stderr,
    File(PathBuf),
}

/// Install the shared subscriber if none is set. Returns nothing on purpose:
/// callers must never fail startup because telemetry could not initialise.
pub fn init(service: &str, default_filter: &str) {
    let sink = match std::env::var_os("IDFON_LOG_FILE") {
        Some(path) => Sink::File(PathBuf::from(path)),
        None => Sink::Stderr,
    };
    install(service, sink, default_filter);
}

/// Like [`init`], but always appends to `path` (the FFI/app path uses a
/// per-process `/tmp/idfon-<pid>.log`).
pub fn init_file(service: &str, path: &Path, default_filter: &str) {
    install(service, Sink::File(path.to_path_buf()), default_filter);
}

/// This process's telemetry participation level, advertised on the `telemetry`
/// envelope field: `inject` once an OTLP endpoint is configured, otherwise
/// `correlate` (every idfon process carries the `trace` id). A peer that does
/// nothing is `none`; unknown values are ignored by receivers.
pub fn mode() -> &'static str {
    #[cfg(feature = "otlp")]
    let exporting = std::env::var_os("IDFON_OTEL_ENDPOINT").is_some();
    #[cfg(not(feature = "otlp"))]
    let exporting = false;
    mode_for(exporting)
}

fn mode_for(exporting: bool) -> &'static str {
    #[cfg(feature = "otlp")]
    if exporting {
        return "inject";
    }
    let _ = exporting;
    "correlate"
}

/// Attach the remote trace in `trace` (a W3C `traceparent`) as the parent of
/// `span`, so a participating process continues the caller's trace instead of
/// starting a new one. The trace is a hint, never an authority. No-op unless
/// the `otlp` feature is compiled in.
pub fn set_remote_parent(span: &tracing::Span, trace: Option<&str>) {
    #[cfg(feature = "otlp")]
    if let Some(traceparent) = trace {
        use opentelemetry::propagation::Extractor;
        use tracing_opentelemetry::OpenTelemetrySpanExt;

        struct Carrier<'a>(&'a str);
        impl Extractor for Carrier<'_> {
            fn get(&self, key: &str) -> Option<&str> {
                key.eq_ignore_ascii_case("traceparent").then_some(self.0)
            }
            fn keys(&self) -> Vec<&str> {
                vec!["traceparent"]
            }
        }

        let context = opentelemetry::global::get_text_map_propagator(|propagator| {
            propagator.extract(&Carrier(traceparent))
        });
        let _ = span.set_parent(context);
    }
    #[cfg(not(feature = "otlp"))]
    {
        let _ = (span, trace);
    }
}

fn filter(default_filter: &str) -> EnvFilter {
    EnvFilter::try_from_env("IDFON_LOG")
        .or_else(|_| EnvFilter::try_from_env("RUST_LOG"))
        .or_else(|_| EnvFilter::try_from_env("IROH_C_LOG"))
        .unwrap_or_else(|_| EnvFilter::new(default_filter))
}

/// Installs the subscriber; `true` when this call won. Idempotent.
fn install(service: &str, sink: Sink, default_filter: &str) -> bool {
    let filter = filter(default_filter);
    let writer = move || -> Box<dyn Write + Send> {
        match &sink {
            Sink::Stderr => Box::new(std::io::stderr()),
            Sink::File(path) => Box::new(
                std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)
                    .unwrap_or_else(|_| {
                        std::fs::File::create("/dev/null").expect("/dev/null unavailable")
                    }),
            ),
        }
    };
    let fmt_layer = tracing_subscriber::fmt::layer()
        .with_ansi(false)
        .with_line_number(true)
        .with_writer(writer);
    let base = tracing_subscriber::registry().with(filter).with(fmt_layer);
    #[cfg(feature = "otlp")]
    let base = base.with(otel_layer(service));
    let installed = base.try_init().is_ok();
    if installed {
        tracing::info!(service, pid = std::process::id(), "telemetry initialised");
    }
    installed
}

#[cfg(feature = "otlp")]
fn otel_layer<S>(
    service: &str,
) -> tracing_opentelemetry::OpenTelemetryLayer<S, opentelemetry::global::BoxedTracer>
where
    S: tracing::Subscriber + for<'span> tracing_subscriber::registry::LookupSpan<'span>,
{
    if let Some(endpoint) = std::env::var_os("IDFON_OTEL_ENDPOINT") {
        init_otlp(service, &endpoint.to_string_lossy());
    }
    let tracer = opentelemetry::global::tracer("idfon");
    tracing_opentelemetry::layer().with_tracer(tracer)
}

#[cfg(feature = "otlp")]
static OTLP_PROVIDER: std::sync::OnceLock<opentelemetry_sdk::trace::SdkTracerProvider> =
    std::sync::OnceLock::new();

#[cfg(feature = "otlp")]
fn init_otlp(service: &str, endpoint: &str) {
    use opentelemetry_otlp::WithExportConfig;

    let exporter = match opentelemetry_otlp::SpanExporter::builder()
        .with_http()
        .with_endpoint(endpoint)
        .build()
    {
        Ok(exporter) => exporter,
        Err(error) => {
            eprintln!("[idfon-telemetry] OTLP exporter init failed for {endpoint}: {error}");
            return;
        }
    };
    let ratio = std::env::var("IDFON_OTEL_SAMPLE_RATIO")
        .ok()
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or(0.1)
        .clamp(0.0, 1.0);
    let name = std::env::var("OTEL_SERVICE_NAME").unwrap_or_else(|_| service.to_owned());
    let resource = opentelemetry_sdk::Resource::builder()
        .with_service_name(name)
        .build();
    let provider = opentelemetry_sdk::trace::SdkTracerProvider::builder()
        .with_batch_exporter(exporter)
        .with_resource(resource)
        .with_sampler(opentelemetry_sdk::trace::Sampler::ParentBased(Box::new(
            opentelemetry_sdk::trace::Sampler::TraceIdRatioBased(ratio),
        )))
        .build();
    opentelemetry::global::set_text_map_propagator(
        opentelemetry_sdk::propagation::TraceContextPropagator::new(),
    );
    opentelemetry::global::set_tracer_provider(provider.clone());
    // Keep the provider alive for the process lifetime; dropping it would stop
    // the batch exporter's background thread. Final spans on abrupt exit may be
    // lost — acceptable for an opt-in dev collector.
    let _ = OTLP_PROVIDER.set(provider);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_is_first_wins() {
        // One process-wide subscriber; the second install must be a no-op.
        assert!(install("test", Sink::Stderr, "info"));
        assert!(!install("test", Sink::Stderr, "info"));
    }

    #[test]
    fn mode_reflects_export() {
        assert_eq!(mode_for(false), "correlate");
        #[cfg(feature = "otlp")]
        assert_eq!(mode_for(true), "inject");
        // Without the exporter compiled in, an endpoint cannot upgrade the mode.
        #[cfg(not(feature = "otlp"))]
        assert_eq!(mode_for(true), "correlate");
    }
}
