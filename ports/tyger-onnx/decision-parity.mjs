// Decision parity over the corpus: the TS chain (bundle -> TygerEngine ->
// TurnSession) vs the fp32 oracle's events from the accepted CoreAI guard run
// (ports/tyger-coreml/parity7.py --cand coreai --dump -> sXX_ref.npz, extracted
// by sessions-prep.py into bench-results/sessions/ref-events.json).
//
// Mirrors parity7's Chain.feed exactly: frame counter is 1-based and increments
// before each frame, mode "response" (the LISTEN rules path), prev_state
// threaded through the engine's onFrame hook, left = hop frames after this one,
// events = non-FRAME (frame, kind). Same-kind events within ±2 frames (80 ms)
// count as one decision.
//
//   node decision-parity.mjs [sessions-dir]
import { readFileSync, existsSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const require = createRequire(join(root, "integrations/eve-idfon-voice/package.json"));
const ort = require("onnxruntime-node");

const { TygerEngine } = await import(join(root, "integrations/eve-idfon-voice/src/tyger/engine.ts"));
const { TurnSession } = await import(join(root, "integrations/eve-idfon-voice/src/tyger/rules.ts"));

const dir = process.argv[2] ?? join(root, "bench-results/sessions");
const GATE = 0.99; // the pre-agreed decision-agreement bar (parity7's guard)

function readWav(path) {
  const b = readFileSync(path);
  let off = 12;
  let data = null;
  while (off + 8 <= b.length) {
    const id = b.toString("ascii", off, off + 4);
    const size = b.readUInt32LE(off + 4);
    if (id === "data") data = b.subarray(off + 8, off + 8 + size);
    off += 8 + size + (size % 2);
  }
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
    if (best >= 0) {
      used.add(best);
      matched++;
    }
  }
  return { matched, onlyRef: ref.length - matched, onlyCand: cand.length - matched };
}

const refEvents = JSON.parse(readFileSync(join(dir, "ref-events.json"), "utf8"));
const bundle = (await import(join(root, "integrations/eve-idfon-voice/src/tyger/bundle.ts"))).loadBundle();
const enc = await ort.InferenceSession.create(bundle.encoderPath);
const step = await ort.InferenceSession.create(bundle.stepPath);

let totalRef = 0;
let totalAligned = 0;
let totalExact = 0;
const tsEventsAll = {};
for (const s of Object.keys(refEvents).sort()) {
  const ch = ["ch0", "ch1"].map((c) => readWav(join(dir, `${s}-${c}.wav`)));
  const nHops = Math.floor(Math.min(ch[0].length, ch[1].length) / 5120);
  const engine = new TygerEngine(enc, step);
  const sess = new TurnSession();
  const events = [];
  let frame = 0;
  for (let h = 0; h < nHops; h++) {
    const x = (h + 1) * 5120;
    const win = ch.map((w) => w.subarray(Math.max(0, x - 8 * 16000), x));
    await engine.hop(win[0], win[1], sess.prev_state, (out8, _i, actDb, left) => {
      frame++;
      const { events: evs } = sess.on_frame("response", out8, actDb, left);
      for (const e of evs) if (e.kind !== "FRAME") events.push([frame, e.kind]);
      return sess.prev_state;
    });
  }
  tsEventsAll[s] = events;
  const ref = refEvents[s];
  const { matched, onlyRef, onlyCand } = aligned(ref, events, 2);
  const exact = ref.filter(([f, k]) => events.some(([g, l]) => g === f && l === k)).length;
  const denom = Math.max(ref.length, events.length);
  totalRef += denom;
  totalAligned += matched;
  totalExact += exact;
  console.log(`  ${s}  frames=${frame}  events ref/ts=${ref.length}/${events.length}  aligned=${matched}  exact=${exact}  only_ref=${onlyRef} only_ts=${onlyCand}`);
}

writeFileSync(join(dir, "ts-events.json"), JSON.stringify(tsEventsAll));
const agreement = totalAligned / totalRef;
const exactness = totalExact / totalRef;
console.log(`\ndecision agreement (±2 frames): ${(agreement * 100).toFixed(2)}%  (${totalAligned}/${totalRef})`);
console.log(`same-frame:                   ${(exactness * 100).toFixed(2)}%`);
console.log(`gate: ${(GATE * 100).toFixed(0)}% -> ${agreement >= GATE ? "PASS" : "FAIL"}`);
process.exit(agreement >= GATE ? 0 : 1);
