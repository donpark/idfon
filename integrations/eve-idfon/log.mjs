// Structured single-line JSON logs for the idfon node scripts (bridge, managed,
// live-relay). One event per line on stderr, tagged with `target` and whatever
// correlation ids the caller has, so agent-side logs join the holder's telemetry
// (see docs/observability.md). stdout is left untouched — it carries protocol
// and data output.
//
// Usage:
//   import { logger } from "./log.mjs";
//   const log = logger("idfon.bridge");
//   log.info("turn received", { message_id, trace });

const SERVICE = process.env.IDFON_SERVICE_NAME ?? "eve-idfon";

function emit(level, target, message, fields) {
  const record = { ts: new Date().toISOString(), level, service: SERVICE, target, message };
  if (fields) {
    for (const [key, value] of Object.entries(fields)) {
      if (value !== undefined && value !== null && value !== "") record[key] = value;
    }
  }
  try {
    process.stderr.write(JSON.stringify(record) + "\n");
  } catch {
    // Logging must never take the process down.
  }
}

export function logger(target) {
  return {
    info: (message, fields) => emit("info", target, message, fields),
    warn: (message, fields) => emit("warn", target, message, fields),
    error: (message, fields) => emit("error", target, message, fields),
  };
}
