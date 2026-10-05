#!/bin/sh
set -eu

# Live OTLP end-to-end against a real collector: a span whose trace id is a
# supplied remote parent must arrive, proving export plus W3C parent extraction.
# Unlike crates/idfon-telemetry/tests/otlp_smoke.rs (in-process, synthetic), this
# exercises the real collector's receiver and file exporter.
#
# Skips cleanly (exit 0) when docker is unavailable, so it is safe to run
# anywhere and to wire into CI. See docs/observability.md "Trying it".

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "otel-e2e: docker unavailable; skipping"
  exit 0
fi

out=$(mktemp -d /tmp/idfon-otel-e2e.XXXXXX)
cid=""
cleanup() {
  if [ -n "$cid" ]; then docker stop "$cid" >/dev/null 2>&1 || true; fi
  rm -rf "$out"
}
trap cleanup EXIT

trace_id=4bf92f3577b34da6a3ce929d0e0e4736
span_id=00f067aa0ba902b7

cid=$(docker run -d --rm -p 4318:4318 -p 13133:13133 \
  -v "$root/scripts/otel-collector.yaml":/etc/otelcol/config.yaml \
  -v "$out":/out \
  otel/opentelemetry-collector:latest \
  --config /etc/otelcol/config.yaml)

# Wait for the collector's health endpoint before emitting.
i=0
while [ "$i" -lt 30 ]; do
  if curl -sf -o /dev/null http://127.0.0.1:13133/; then break; fi
  i=$((i + 1))
  sleep 1
done

IDFON_OTEL_ENDPOINT=http://127.0.0.1:4318/v1/traces \
IDFON_OTEL_SAMPLE_RATIO=1.0 \
IDFON_OTEL_PARENT="00-$trace_id-$span_id-01" \
  cargo run -q -p idfon-telemetry --features otlp --example emit_span

# The file exporter flushes on a short interval; poll for the trace id.
i=0
while [ "$i" -lt 20 ]; do
  if [ -f "$out/spans.json" ] && grep -q "$trace_id" "$out/spans.json"; then
    echo "otel-e2e: ok (trace $trace_id received)"
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done

echo "otel-e2e: FAILED (no trace $trace_id in collector output)" >&2
if [ -f "$out/spans.json" ]; then tail -5 "$out/spans.json" >&2; fi
exit 1
