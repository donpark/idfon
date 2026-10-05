// Structured single-line JSON logs for the Eve extension, mirroring log.mjs so
// agent output joins the holder's telemetry (`target` + correlation ids). The
// extension is bundled by `eve extension build`; keep this dependency-free.
// stderr only: stdout is left to the runtime.

const SERVICE = process.env.IDFON_SERVICE_NAME ?? "eve-idfon";

type Fields = Record<string, unknown>;

function emit(level: "info" | "warn" | "error", target: string, message: string, fields?: Fields) {
  const record: Fields = { ts: new Date().toISOString(), level, service: SERVICE, target, message };
  if (fields) {
    for (const [key, value] of Object.entries(fields)) {
      if (value !== undefined && value !== null && value !== "") record[key] = value;
    }
  }
  process.stderr.write(JSON.stringify(record) + "\n");
}

export function logger(target: string) {
  return {
    info: (message: string, fields?: Fields) => emit("info", target, message, fields),
    warn: (message: string, fields?: Fields) => emit("warn", target, message, fields),
    error: (message: string, fields?: Fields) => emit("error", target, message, fields),
  };
}
