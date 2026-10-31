// The int8 model via onnxruntime-node: loads, runs on synthetic silence and a
// speech-ish signal without crashing, outputs finite, and the threaded state
// keeps a stream stable. Skips gracefully when the bundle is not installed
// (hermetic decision logic lives in bcd-decisions.test.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";

import { loadBundle } from "../src/bcd/bundle.ts";
import { BcdEngine, botStateRow, CHUNK_N, FRAMES_PER_CHUNK } from "../src/bcd/engine.ts";

const require = createRequire(import.meta.url);
const ort = require("onnxruntime-node");

const bundleDir = process.env.IDFON_BCD_BUNDLE ?? join(homedir(), ".idfon/models/bcd");
const haveModel = existsSync(join(bundleDir, "model.json")) &&
  (existsSync(join(bundleDir, "backchannel-int8.onnx")) || existsSync(join(bundleDir, "backchannel-fp32.onnx")));

// "bot long silent" shadow row, two frames
const BOT_STATE = [...botStateRow(false, 5, 5, 5), ...botStateRow(false, 5, 5, 5)];

async function makeEngine(): Promise<BcdEngine> {
  const bundle = loadBundle();
  return new BcdEngine(await ort.InferenceSession.create(bundle.modelPath));
}

function assertFinite(frames: Array<{ intent: number[]; vad: number; vap: number[] }>): void {
  for (const f of frames) {
    assert.equal(f.intent.length, 5);
    assert.equal(f.vap.length, 8);
    for (const x of [...f.intent, f.vad, ...f.vap]) {
      assert.ok(Number.isFinite(x), `non-finite output: ${x}`);
    }
  }
}

test("model loads and runs on silence and speech-ish signal", { skip: !haveModel }, async () => {
  const engine = await makeEngine();
  const all = [];
  for (let i = 0; i < 25; i++) all.push(...(await engine.chunk(new Float32Array(CHUNK_N), BOT_STATE)));
  // 1 s of a modulated 200 Hz tone with a little noise — speech-ish, [-1, 1]
  const speech = new Float32Array(CHUNK_N);
  for (let i = 0; i < CHUNK_N; i++) {
    const t = (i + 25 * CHUNK_N) / 16000;
    speech[i] = 0.4 * Math.sin(2 * Math.PI * 200 * t) * (0.5 + 0.5 * Math.sin(2 * Math.PI * 3 * t))
      + 0.02 * Math.sin(2 * Math.PI * 31 * i);
  }
  for (let i = 0; i < 25; i++) all.push(...(await engine.chunk(speech, BOT_STATE)));
  assert.equal(all.length, 50 * FRAMES_PER_CHUNK);
  assertFinite(all);
});

test("state threading is stable across a stream", { skip: !haveModel }, async () => {
  const engine = await makeEngine();
  const zeros = new Float32Array(CHUNK_N);
  // a long quiet stream must not drift into NaN/garbage via the *_out loop
  for (let i = 0; i < 100; i++) {
    const frames = await engine.chunk(zeros, BOT_STATE);
    assertFinite(frames);
  }
  // reset restores the zero-state behaviour
  engine.reset();
  const after = await engine.chunk(zeros, BOT_STATE);
  const fresh = await (await makeEngine()).chunk(zeros, BOT_STATE);
  for (let f = 0; f < FRAMES_PER_CHUNK; f++) {
    assert.deepEqual(after[f].intent, fresh[f].intent);
    assert.equal(after[f].vad, fresh[f].vad);
  }
});

test("chunk rejects wrong sizes", { skip: !haveModel }, async () => {
  const engine = await makeEngine();
  await assert.rejects(engine.chunk(new Float32Array(320), BOT_STATE), /want 640/);
  await assert.rejects(engine.chunk(new Float32Array(CHUNK_N), new Float32Array(8)), /want 16/);
});
