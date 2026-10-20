// Decision parity for the bundle loader: verify() passes on intact files and
// names the file on corruption — with tiny stand-in files, never the 1.5 GB ones.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadBundle } from "../src/tyger/bundle.ts";

function fakeBundle(dir: string): void {
  mkdirSync(dir, { recursive: true });
  const files = ["TygerEncoderDyn.onnx", "TygerEncoderDyn.onnx.data", "TygerStep.onnx", "TygerStep.onnx.data"]
    .map((name) => {
      const body = Buffer.from(`fake:${name}`);
      writeFileSync(join(dir, name), body);
      return { name, bytes: body.length, sha256: createHash("sha256").update(body).digest("hex") };
    });
  writeFileSync(join(dir, "manifest.json"), JSON.stringify({
    version: 1, created: "2026-10-20", source: { bundle: "nineninesix/tyger" },
    url_base: null, files, io: {},
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
