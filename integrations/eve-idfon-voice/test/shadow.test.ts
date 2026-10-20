// The shadow's stream glue: 24k->16k resampling keeps the sample-count ratio,
// and s16 decoding round-trips.
import { test } from "node:test";
import assert from "node:assert/strict";
import { makeResampler, pcm16ToFloat } from "../src/tyger/shadow.ts";

test("resampler 24k->16k keeps the ratio", () => {
  const resample = makeResampler();
  const n = 24000; // 1 s at 24 kHz
  const x = new Float32Array(n).map((_, i) => Math.sin((2 * Math.PI * 440 * i) / 24000));
  const out = resample(x);
  assert.ok(Math.abs(out.length - 16000) <= 2, `got ${out.length} samples for 1 s`);
  // streamed in chunks the total is the same
  const resample2 = makeResampler();
  let total = 0;
  for (let i = 0; i < n; i += 1024) total += resample2(x.subarray(i, i + 1024)).length;
  assert.ok(Math.abs(total - out.length) <= 2, `chunked ${total} vs whole ${out.length}`);
});

test("pcm16 round-trips", () => {
  const samples = Float32Array.from([0, 0.5, -0.5, 1, -1]);
  const buf = Buffer.alloc(samples.length * 2);
  for (let i = 0; i < samples.length; i++) buf.writeInt16LE(Math.round(samples[i] * 32767), i * 2);
  const back = pcm16ToFloat(new Uint8Array(buf));
  for (let i = 0; i < samples.length; i++) {
    assert.ok(Math.abs(back[i] - samples[i]) < 1e-4, `sample ${i}: ${back[i]} vs ${samples[i]}`);
  }
});
