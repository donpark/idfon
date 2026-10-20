// Composed-chain parity: TS mel -> ONNX encoder -> ONNX step over the runtime
// fixture audio (ports/tyger-swift/Tests/TygerVoiceTests/runtime/ch{0,1}.wav),
// compared against expectations.json (the torch oracle's per-frame 8-vectors,
// prev_state held at 0 — the numeric chain in isolation, like TurnRuntimeTests).
//
//   node engine-parity.mjs
// Uses the product package's onnxruntime-node (integrations/eve-idfon-voice), so
// Tensor instances are the same module's — a second install breaks session.run.
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const require = createRequire(join(root, "integrations/eve-idfon-voice/package.json"));
const ort = require("onnxruntime-node");
const { TygerEngine } = await import(
  join(root, "integrations/eve-idfon-voice/src/tyger/engine.ts"));
const runtime = join(root, "ports/tyger-swift/Tests/TygerVoiceTests/runtime");

const GATE = 0.02; // the accepted on-device tier's per-head drift envelope is 0.06 (probs)
// / 0.7 (state logits); fp32 ORT should land near 1e-3. Fail > 0.02 either way.

/// Minimal WAV reader for the soundfile "FLOAT" wavs (32-bit IEEE, mono).
function readWav(path) {
  const b = readFileSync(path);
  let off = 12;
  let fmt = null;
  let data = null;
  while (off + 8 <= b.length) {
    const id = b.toString("ascii", off, off + 4);
    const size = b.readUInt32LE(off + 4);
    if (id === "fmt ") fmt = { format: b.readUInt16LE(off + 8), channels: b.readUInt16LE(off + 10), rate: b.readUInt32LE(off + 12) };
    if (id === "data") data = b.subarray(off + 8, off + 8 + size);
    off += 8 + size + (size % 2);
  }
  if (!fmt || fmt.format !== 3 || fmt.channels !== 1) throw new Error(`unexpected wav: ${JSON.stringify(fmt)}`);
  return { samples: new Float32Array(data.buffer, data.byteOffset, data.length / 4), rate: fmt.rate };
}

const ch = ["ch0", "ch1"].map((c) => readWav(join(runtime, `${c}.wav`)).samples);
const hop = 5120;
const nHops = Math.floor(Math.min(ch[0].length, ch[1].length) / hop);

const enc = await ort.InferenceSession.create(join(root, "bench-results/onnx/TygerEncoderDyn.onnx"));
const step = await ort.InferenceSession.create(join(root, "bench-results/onnx/TygerStep.onnx"));
const engine = new TygerEngine(enc, step);

const { frames: want } = JSON.parse(readFileSync(join(runtime, "expectations.json"), "utf8"));
let idx = 0;
let worst = 0;
const t0 = Date.now();
for (let h = 0; h < nHops; h++) {
  const s = (h + 1) * hop;
  // the NEW hop only — TygerEngine accumulates the 8 s windows itself
  const newHop = ch.map((w) => w.subarray(Math.max(0, s - hop), s));
  const outs = await engine.hop(newHop[0], newHop[1], 0);
  for (const out of outs) {
    if (idx >= want.length) break;
    for (let j = 0; j < 8; j++) worst = Math.max(worst, Math.abs(out[j] - want[idx][j]));
    idx++;
  }
}
const ms = Date.now() - t0;
console.log(`frames: ${idx}/${want.length} over ${nHops} hops (${ms} ms total, ${(ms / nHops).toFixed(0)} ms/hop)`);
console.log(`max|Δ| out8: ${worst.toExponential(3)}  (gate ${GATE})`);
const pass = worst <= GATE && idx === want.length;
console.log(pass ? "PASS" : "FAIL");
process.exit(pass ? 0 : 1);
