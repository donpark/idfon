// The bundle loader: picks int8 over fp32, honours the dir/env override, and
// refuses a model.json that diverges from the engine contract. Tiny stand-in
// files — never the real megabytes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadBundle } from "../src/bcd/bundle.ts";

const MODEL_JSON = {
  chunk_samples: 640,
  frames_per_chunk: 2,
  state_names: [
    "audio_cache",
    "stem_cache",
    "block0_cache",
    "block1_cache",
    "block2_cache",
    "block3_cache",
    "gru_state",
  ],
  config: {},
};

function fakeBundle(dir: string, modelJson: object = MODEL_JSON): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "backchannel-int8.onnx"), "fake:int8");
  writeFileSync(join(dir, "backchannel-fp32.onnx"), "fake:fp32");
  writeFileSync(join(dir, "model.json"), JSON.stringify(modelJson));
}

test("loader prefers int8 and honours the dir override", () => {
  const dir = join(tmpdir(), `bcd-bundle-test-${process.pid}`);
  rmSync(dir, { recursive: true, force: true });
  fakeBundle(dir);

  const b = loadBundle(dir);
  assert.equal(b.modelPath, join(dir, "backchannel-int8.onnx"));
  assert.equal(b.modelConfig.chunk_samples, 640);

  rmSync(join(dir, "backchannel-int8.onnx"));
  assert.equal(loadBundle(dir).modelPath, join(dir, "backchannel-fp32.onnx"));
  rmSync(dir, { recursive: true, force: true });
});

test("loader refuses a divergent model.json and missing files", () => {
  const dir = join(tmpdir(), `bcd-bundle-diverge-test-${process.pid}`);
  rmSync(dir, { recursive: true, force: true });

  assert.throws(() => loadBundle(dir), /no backchannel-int8\.onnx.*download it first/s);

  fakeBundle(dir, { ...MODEL_JSON, chunk_samples: 320 });
  assert.throws(() => loadBundle(dir), /chunk_samples 320/);

  fakeBundle(dir, { ...MODEL_JSON, state_names: ["gru_state"] });
  assert.throws(() => loadBundle(dir), /state_names/);
  rmSync(dir, { recursive: true, force: true });
});
