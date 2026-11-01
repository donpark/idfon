// P0 gate for the int8-stored turn-taker (docs/voice-decision-model.md): run
// the composed chain (TS mel -> ONNX encoder -> step) over the runtime fixture
// audio with the fp32 step AND the candidate step, and judge the candidate the
// way the brief defines it:
//   - numeric pass (prev_state pinned at 0, the parity drive's contract):
//     per-head |Δ| of cand vs the fp32 reference ≤ 0.02 on the 4 probabilities
//     (the S3 acceptance envelope — quantization budget) and vs the torch
//     oracle (expectations.json) within the fp32 chain's own drift;
//   - decision pass (floor state threaded through TurnSession, real drive):
//     same-kind events within ±2 frames = one decision; every event must match
//     and per-frame state decisions must not flip.
//
//   node ports/tyger-onnx/qstep-parity.mjs [path/to/TygerStepInt8.onnx]
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
const { TygerEngine } = await import(join(root, "integrations/eve-idfon-voice/src/tyger/engine.ts"));
const { TurnSession } = await import(join(root, "integrations/eve-idfon-voice/src/tyger/rules.ts"));

const runtime = join(root, "ports/tyger-swift/Tests/TygerVoiceTests/runtime");
const candPath = resolve(process.argv[2] ?? join(root, "bench-results/onnx/TygerStepInt8.onnx"));
const PROB_GATE = 0.02; // S3 per-head envelope on the 4 probabilities (vs the fp32 reference)
const HEADS = ["state[LISTEN]", "state[HOLD]", "state[SPEAK]", "state[BACKCHANNEL]", "hazard", "yield", "bc", "p_end"];

function readWav(path) {
  const b = readFileSync(path);
  let off = 12, fmt = null, data = null;
  while (off + 8 <= b.length) {
    const id = b.toString("ascii", off, off + 4);
    const size = b.readUInt32LE(off + 4);
    if (id === "fmt ") fmt = { format: b.readUInt16LE(off + 8), channels: b.readUInt16LE(off + 10) };
    if (id === "data") data = b.subarray(off + 8, off + 8 + size);
    off += 8 + size + (size % 2);
  }
  if (!fmt || fmt.format !== 3 || fmt.channels !== 1) throw new Error(`unexpected wav: ${JSON.stringify(fmt)}`);
  return new Float32Array(data.buffer, data.byteOffset, data.length / 4);
}

/// Same-kind events within tol frames = one decision (parity7's aligned_count).
function aligned(ref, cand, tol) {
  const used = new Set();
  let matched = 0;
  for (const [rf, rk] of ref) {
    let best = -1;
    for (let i = 0; i < cand.length; i++) {
      if (used.has(i) || cand[i][1] !== rk) continue;
      const d = Math.abs(cand[i][0] - rf);
      if (d <= tol && (best < 0 || d < Math.abs(cand[best][0] - rf))) best = i;
    }
    if (best >= 0) { used.add(best); matched++; }
  }
  return { matched, onlyRef: ref.length - matched, onlyCand: cand.length - matched };
}

const ch = ["ch0", "ch1"].map((c) => readWav(join(runtime, `${c}.wav`)));
const hop = 5120;
const nHops = Math.floor(Math.min(ch[0].length, ch[1].length) / hop);
const { frames: want } = JSON.parse(readFileSync(join(runtime, "expectations.json"), "utf8"));

const enc = await ort.InferenceSession.create(join(root, "bench-results/onnx/TygerEncoderDyn.onnx"));
const stepFp32 = await ort.InferenceSession.create(join(root, "bench-results/onnx/TygerStep.onnx"));
const stepQ = await ort.InferenceSession.create(candPath);

/// Numeric pass: prev_state pinned at 0 (engine-parity's drive) -> per-frame 8-vectors.
async function runPinned(step) {
  const engine = new TygerEngine(enc, step);
  const outs = [];
  for (let h = 0; h < nHops; h++) {
    const x = (h + 1) * hop;
    const win = ch.map((w) => w.subarray(Math.max(0, x - hop), x));
    outs.push(...(await engine.hop(win[0], win[1], 0)));
  }
  return outs;
}

/// Decision pass: floor state threaded through the rules -> events + state flips.
async function runDecision(step, track) {
  const engine = new TygerEngine(enc, step);
  const sess = new TurnSession();
  const events = [];
  let frame = 0, stateFlips = 0;
  for (let h = 0; h < nHops; h++) {
    const x = (h + 1) * hop;
    const win = ch.map((w) => w.subarray(Math.max(0, x - hop), x));
    await engine.hop(win[0], win[1], sess.prev_state, (out8, _i, actDb, left) => {
      frame++;
      const prev = sess.prev_state;
      const { events: evs } = sess.on_frame("response", out8, actDb, left);
      for (const e of evs) if (e.kind !== "FRAME") events.push([frame, e.kind]);
      if (track && sess.prev_state !== prev) stateFlips++;
      return sess.prev_state;
    });
  }
  return { events, frame, stateFlips };
}

const t0 = Date.now();
const fpPinned = await runPinned(stepFp32);
const qPinned = await runPinned(stepQ);
const fp = await runDecision(stepFp32, false);
const q = await runDecision(stepQ, true);
console.log(`cand: ${candPath.replace(root + "/", "")}`);
console.log(`frames: ${qPinned.length}/${want.length} over ${nHops} hops (${Date.now() - t0} ms, all runs)\n`);

// numeric pass: cand vs the fp32 reference (the quantization budget) and both vs oracle
const dvFp = new Array(8).fill(0), dvOr = new Array(8).fill(0), fpOr = new Array(8).fill(0);
for (let i = 0; i < Math.min(qPinned.length, want.length); i++) {
  for (let j = 0; j < 8; j++) {
    dvFp[j] = Math.max(dvFp[j], Math.abs(qPinned[i][j] - fpPinned[i][j]));
    dvOr[j] = Math.max(dvOr[j], Math.abs(qPinned[i][j] - want[i][j]));
    fpOr[j] = Math.max(fpOr[j], Math.abs(fpPinned[i][j] - want[i][j]));
  }
}
console.log("per-head max|Δ| — cand vs fp32 reference (cand/oracle, fp32/oracle for scale):");
for (let j = 0; j < 8; j++) {
  const gate = j >= 4 ? `  (prob gate ${PROB_GATE})` : "";
  console.log(`  ${HEADS[j].padEnd(18)} ${dvFp[j].toExponential(3)}  (${dvOr[j].toExponential(3)}, ${fpOr[j].toExponential(3)})${gate}`);
}

// decision pass: fp32 chain's rules events vs the candidate's
const { matched, onlyRef, onlyCand } = aligned(fp.events, q.events, 2);
console.log(`\nevents fp32/cand = ${fp.events.length}/${q.events.length}  aligned(±2) = ${matched}  only_fp32 = ${onlyRef} only_cand = ${onlyCand}`);
if (onlyRef || onlyCand) {
  console.log(`  fp32: ${JSON.stringify(fp.events)}`);
  console.log(`  cand: ${JSON.stringify(q.events)}`);
}
console.log(`state-decision flips vs fp32 chain: ${q.stateFlips}/${q.frame}`);

const probsOk = dvFp.slice(4).every((d) => d <= PROB_GATE);
const decOk = onlyRef === 0 && onlyCand === 0 && q.stateFlips === 0;
const pass = probsOk && decOk;
console.log(`\nprobs vs fp32 ≤ ${PROB_GATE}: ${probsOk ? "PASS" : "FAIL"}   decisions/state identical: ${decOk ? "PASS" : "FAIL"}`);
console.log(pass ? "PASS" : "FAIL");
process.exit(pass ? 0 : 1);
