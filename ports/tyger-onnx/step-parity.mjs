// Node parity gate for TygerStep.onnx (ports/tyger-onnx/export_step.py writes the inputs
// and the torch oracle's outputs). Runs every dumped frame through onnxruntime-node and
// diffs out + state_out against the oracle.
//
//   node step-parity.mjs [path/to/step-oracle.json]
// Uses the product package's onnxruntime-node (integrations/eve-idfon-voice), so
// Tensor instances are the same module's — a second install breaks session.run.
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(join(resolve(dirname(fileURLToPath(import.meta.url)), "../.."), "integrations/eve-idfon-voice/package.json"));
const ort = require("onnxruntime-node");

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const oraclePath = resolve(process.argv[2] ?? join(root, "bench-results/onnx/step-oracle.json"));
const modelPath = join(root, "bench-results/onnx/TygerStep.onnx");
const GATE = 1e-4;          // step: fp32 export/ORT noise
const ENC_GATE = 1e-3;      // encoder: fp32 reassociation over 24 attention layers (~2e-4 measured;
                            // same order as the CoreAI fp32 gate). The DECISION outputs are the contract.

const { frames } = JSON.parse(readFileSync(oraclePath, "utf8"));
const session = await ort.InferenceSession.create(modelPath);

const f32 = (a) => new ort.Tensor("float32", Float32Array.from(a), [1, 1, 1024]);
const maxDiff = (a, b) => a.reduce((m, v, i) => Math.max(m, Math.abs(v - b[i])), 0);

let worstOut = 0, worstState = 0;
for (const f of frames) {
  const feeds = {
    hu: f32(f.hu),
    ha: f32(f.ha),
    act_db: new ort.Tensor("float32", Float32Array.from([f.act_db]), [1, 1]),
    prev_state: new ort.Tensor("int64", BigInt64Array.from([0n]), [1, 1]),
    state: new ort.Tensor("float32", Float32Array.from(f.state_in), [3, 1, 768]),
  };
  const r = await session.run(feeds);
  worstOut = Math.max(worstOut, maxDiff(Array.from(r.out.data), f.out));
  worstState = Math.max(worstState, maxDiff(Array.from(r.state_out.data), f.state_out));
}

console.log(`frames: ${frames.length}`);
console.log(`max|Δ| out:   ${worstOut.toExponential(3)}  (gate ${GATE})`);
console.log(`max|Δ| state: ${worstState.toExponential(3)}  (gate ${GATE})`);

// The encoder half (TygerEncoder.onnx + enc-oracle.json), when present.
let encPass = true;
const encOraclePath = join(root, "bench-results/onnx/enc-oracle.json");
if (existsSync(encOraclePath)) {
  const eo = JSON.parse(readFileSync(encOraclePath, "utf8"));
  const enc = await ort.InferenceSession.create(join(root, "bench-results/onnx/TygerEncoder.onnx"));
  const r = await enc.run({ mel: new ort.Tensor("float32", Float32Array.from(eo.mel), eo.mel_shape) });
  const d = maxDiff(Array.from(r.hidden.data), eo.hidden);
  encPass = d <= ENC_GATE;
  console.log(`max|Δ| hidden: ${d.toExponential(3)}  (gate ${ENC_GATE}, shape ${eo.hidden_shape})`);
}

const pass = worstOut <= GATE && worstState <= GATE && encPass;
console.log(pass ? "PASS" : "FAIL");
process.exit(pass ? 0 : 1);
