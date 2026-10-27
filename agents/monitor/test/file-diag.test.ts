import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileReport } from "../agent/lib/file-diag.ts";

function tmp() {
  return mkdtempSync(join(tmpdir(), "diag-test-"));
}

test("files a report as one jsonl line per event", () => {
  const dir = tmp();
  const report = {
    device: "iphone",
    build: "2026-10-24.wakefix1",
    events: [
      { ts_ms: 1, kind: "push.received", detail: { call: "c1" } },
      { ts_ms: 2, kind: "wake", detail: { outcome: "presented" } },
    ],
  };
  const filed = fileReport(dir, "IDFON-DIAG/1\n" + JSON.stringify(report));
  assert.equal(filed, 2);
  const lines = readFileSync(join(dir, "iphone.jsonl"), "utf8")
    .trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(lines.length, 2);
  assert.equal(lines[0].kind, "push.received");
  assert.equal(lines[0].device, "iphone");
  assert.equal(lines[0].detail.call, "c1");
  assert.equal(lines[1].build, "2026-10-24.wakefix1");
});

test("ignores non-diag text and drops bad json", () => {
  const dir = tmp();
  assert.equal(fileReport(dir, "hello there"), 0);
  assert.equal(fileReport(dir, "IDFON-DIAG/1\n{nope"), -1);
});

test("caps events at the protocol bound", () => {
  const dir = tmp();
  const events = Array.from({ length: 200 }, (_, ts_ms) => ({ ts_ms, kind: "k", detail: {} }));
  const filed = fileReport(dir, "IDFON-DIAG/1\n" + JSON.stringify({ device: "d", build: "b", events }));
  assert.equal(filed, 64);
  const lines = readFileSync(join(dir, "d.jsonl"), "utf8").trim().split("\n");
  assert.equal(lines.length, 64);
});

test("keeps the device name path-safe", () => {
  const dir = tmp();
  fileReport(dir, "IDFON-DIAG/1\n" + JSON.stringify({
    device: "../evil name", build: "b", events: [{ ts_ms: 1, kind: "k", detail: {} }],
  }));
  const lines = readFileSync(join(dir, ".._evil_name.jsonl"), "utf8").trim().split("\n");
  assert.equal(lines.length, 1);
  assert.equal(JSON.parse(lines[0]).device, "../evil name");
});

test("rotates to one generation when the file passes the size cap", () => {
  const dir = tmp();
  const big = (tag: string) => "IDFON-DIAG/1\n" + JSON.stringify({
    device: "d", build: "b",
    events: [{ ts_ms: 1, kind: "k", detail: { tag, pad: "x".repeat(1024) } }],
  });
  // Overfill with many reports, then check the generation files.
  for (let i = 0; i < 9000; i++) fileReport(dir, big("t" + i));
  assert.ok(statSync(join(dir, "d.jsonl.1")).size > 0, "previous generation kept");
  assert.ok(statSync(join(dir, "d.jsonl")).size > 0, "current file keeps appending");
});
