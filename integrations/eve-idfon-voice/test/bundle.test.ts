// Decision parity for the bundle loader: verify() passes on intact files and
// names the file on corruption — with tiny stand-in files, never the 1.5 GB ones.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadBundle } from "../src/tyger/bundle.ts";

function fakeBundle(dir: string, steps = ["TygerStep.onnx", "TygerStep.onnx.data"], io: object = {}): void {
  mkdirSync(dir, { recursive: true });
  const files = ["TygerEncoderDyn.onnx", "TygerEncoderDyn.onnx.data", ...steps]
    .map((name) => {
      const body = Buffer.from(`fake:${name}`);
      writeFileSync(join(dir, name), body);
      return { name, bytes: body.length, sha256: createHash("sha256").update(body).digest("hex") };
    });
  writeFileSync(join(dir, "manifest.json"), JSON.stringify({
    version: 1, created: "2026-10-20", source: { bundle: "nineninesix/tyger" },
    url_base: null, files, io,
  }));
}

test("bundle verifies intact and rejects corruption", () => {
  const dir = join(tmpdir(), `tyger-bundle-test-${process.pid}`);
  rmSync(dir, { recursive: true, force: true });
  fakeBundle(dir);

  const b = loadBundle(dir);
  assert.equal(b.manifest.version, 1);
  assert.equal(b.encoderPath, join(dir, "TygerEncoderDyn.onnx"));

  writeFileSync(join(dir, "TygerStep.onnx"), "corrupt");
  assert.throws(() => loadBundle(dir), /bundle corrupt: TygerStep\.onnx/);
  rmSync(dir, { recursive: true, force: true });
});

/// The student swap (issue #104): the loader prefers StudentStep.onnx and takes
/// the carried-state shape from the packer's io contract (2x256 vs 3x768).
test("student step is preferred and its state shape comes from the manifest", () => {
  const dir = join(tmpdir(), `tyger-student-bundle-test-${process.pid}`);
  rmSync(dir, { recursive: true, force: true });
  fakeBundle(dir, ["StudentStep.onnx", "TygerStep.onnx", "TygerStep.onnx.data"], {
    step: { inputs: { state: ["2", "1", "256"] }, outputs: { state_out: ["2", "1", "256"] } },
  });
  const b = loadBundle(dir);
  assert.equal(b.stepPath, join(dir, "StudentStep.onnx"));
  assert.deepEqual(b.stateShape, [2, 1, 256]);
  rmSync(dir, { recursive: true, force: true });
});

test("teacher bundle without an io contract keeps 3x768", () => {
  const dir = join(tmpdir(), `tyger-teacher-bundle-test-${process.pid}`);
  rmSync(dir, { recursive: true, force: true });
  fakeBundle(dir);
  const b = loadBundle(dir);
  assert.equal(b.stepPath, join(dir, "TygerStep.onnx"));
  assert.deepEqual(b.stateShape, [3, 1, 768]);
  rmSync(dir, { recursive: true, force: true });
});
