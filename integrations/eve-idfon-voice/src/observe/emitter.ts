// JSONL sink for per-call records (src/observe/README.md). Passive by design:
// callers swallow errors — losing a record must never touch the call.

import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import type { CallRecord } from "./schema.ts";

/** Where call records go: `IDFON_CALL_RECORDS` overrides the path; the value
 * "off" disables emission entirely. */
export function callRecordPath(): string | null {
  const override = process.env.IDFON_CALL_RECORDS;
  if (override === "off") return null;
  return override || join(homedir(), ".idfon", "observe", "calls.jsonl");
}

/** Append one record as one JSONL line. */
export function appendCallRecord(path: string, record: CallRecord): void {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(record) + "\n");
}
