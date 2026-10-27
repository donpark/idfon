// Filing for IDFON-DIAG/1 reports (docs/diag.md, issue #63): parse one report
// envelope and append its events as JSONL under `dir` — one line per event,
// with the report's device and build stamp attached. Pure node:fs so the hook
// and the tests share one implementation.
import { appendFileSync, mkdirSync, renameSync, statSync } from "node:fs";
import { join } from "node:path";

const PREFIX = "IDFON-DIAG/1\n";
// The protocol bound (crates/idfon-protocol/src/diag.rs): never file more.
const MAX_EVENTS = 64;
// One rotated generation, size-capped: a monitor runs unattended, so the
// files must not grow without bound (docs/diag.md open item).
const MAX_BYTES = 8 * 1024 * 1024;

export function fileReport(dir: string, text: string): number {
  if (!text.startsWith(PREFIX)) return 0;
  let report: any;
  try {
    report = JSON.parse(text.slice(PREFIX.length));
  } catch {
    return -1;
  }
  const device = typeof report?.device === "string" && report.device ? report.device : "unknown";
  const build = typeof report?.build === "string" ? report.build : "unknown";
  const events: any[] = Array.isArray(report?.events) ? report.events.slice(0, MAX_EVENTS) : [];
  if (events.length === 0) return 0;
  mkdirSync(dir, { recursive: true });
  const filed_ms = Date.now();
  const lines = events.map((event) =>
    JSON.stringify({
      device,
      build,
      ts_ms: event?.ts_ms ?? 0,
      kind: event?.kind ?? "unknown",
      detail: event?.detail ?? {},
      filed_ms,
    }));
  // The device name becomes a filename; keep it path-safe.
  const safe = device.replace(/[^A-Za-z0-9._-]/g, "_");
  const file = join(dir, `${safe}.jsonl`);
  let existing = 0;
  try {
    existing = statSync(file).size;
  } catch {
    // no file yet
  }
  const chunk = lines.join("\n") + "\n";
  if (existing + chunk.length > MAX_BYTES) {
    renameSync(file, `${file}.1`); // replaces the previous generation
  }
  appendFileSync(file, chunk);
  return events.length;
}
