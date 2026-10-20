#!/usr/bin/env node
// voice-agent-trainer: run a recorded conversation through the decision chain
// and show what the turn model decides — the lightweight iteration harness for
// threshold/trait/precision work (the corpus guards in ports/tyger-onnx are
// the slow, exact version of this).
//
//   node voice-agent-trainer.mjs <recording.wav> [--thresholds '{"ep_thr":0.85}']
//                               [--json out.json] [--quiet]
//
// Input kinds (auto-detected):
//   * stereo, DIFFERENT channels = ch0 mic, ch1 agent playback — the two-stream
//     tyger format, which is **idfon's native capture**: the apps' TurnShadow
//     records every call as exactly this (mac: ~/Library/Application
//     Support/Idfon/turn-captures/, iOS: Documents/turn-captures/; the
//     `turn-capture:` Automation mark names the file). idfon voices are never
//     mixed — mic and playback are separate streams — so live calls are ideal
//     training/tuning data. While the agent channel is loud the hop runs in
//     "speaking" mode (hysteresis: a speaking episode releases after 6 quiet
//     hops), so BARGE decisions mean something.
//   * mono — or stereo with IDENTICAL channels (a mix duplicated) — = the mix
//     only (e.g. a demo recording). No agent stream exists: agent = silence,
//     mode stays "listen", and the model treats the whole conversation as the
//     caller's speech. ENDPOINT/BACKCHANNEL still land at the model's notion of
//     turn edges, but BARGE is meaningless and agent turns look like caller
//     turns. The header says so.
//
// Output: the decision timeline with the margin each decision cleared by, the
// closest non-firing approaches per head (the "why did it not fire" view), and
// a downsampled p_end/yield/bc trace against their thresholds.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const require = createRequire(join(root, "integrations/eve-idfon-voice/package.json"));
const ort = require("onnxruntime-node");

const { loadBundle } = await import(join(root, "integrations/eve-idfon-voice/src/tyger/bundle.ts"));
const { TygerEngine } = await import(join(root, "integrations/eve-idfon-voice/src/tyger/engine.ts"));
const { frameEnergy, TurnSession, DEFAULT_THRESHOLDS, HOP_N, SR } =
  await import(join(root, "integrations/eve-idfon-voice/src/tyger/rules.ts"));
const { makeResampler } = await import(join(root, "integrations/eve-idfon-voice/src/tyger/stream.ts"));

const args = process.argv.slice(2);
const wavPath = args.find((a) => !a.startsWith("--"));
const argOf = (f) => (args.includes(f) ? args[args.indexOf(f) + 1] : undefined);
const thresholds = argOf("--thresholds") ? JSON.parse(argOf("--thresholds")) : {};
const jsonOut = argOf("--json");
const quiet = args.includes("--quiet");
if (!wavPath) {
  console.error("usage: node voice-agent-trainer.mjs <recording.wav> [--thresholds '{...}'] [--json out.json] [--quiet]");
  process.exit(2);
}

/// Minimal wav reader: PCM s16, any channel count (ch0 = user, ch1 = agent).
function readWav(path) {
  const b = readFileSync(path);
  let off = 12, fmt = null, data = null;
  while (off + 8 <= b.length) {
    const id = b.toString("ascii", off, off + 4);
    const size = b.readUInt32LE(off + 4);
    if (id === "fmt ") fmt = { format: b.readUInt16LE(off + 8), channels: b.readUInt16LE(off + 10), rate: b.readUInt32LE(off + 12) };
    if (id === "data") data = b.subarray(off + 8, off + 8 + size);
    off += 8 + size + (size % 2);
  }
  if (!fmt || fmt.format !== 1) throw new Error(`only PCM wav supported: ${JSON.stringify(fmt)}`);
  const frames = data.length / 2 / fmt.channels;
  const user = new Float32Array(frames);
  const agent = new Float32Array(frames);
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  for (let i = 0; i < frames; i++) {
    user[i] = view.getInt16(2 * (i * fmt.channels), true) / 32768;
    agent[i] = fmt.channels > 1 ? view.getInt16(2 * (i * fmt.channels + 1), true) / 32768 : 0;
  }
  return { user, agent, rate: fmt.rate, channels: fmt.channels };
}

function resample(x, rate) {
  if (rate === SR) return Array.from(x);
  const r = makeResampler(rate, SR);
  return r(x);
}

const wav = readWav(wavPath);
// A duplicated-channel stereo is a mix, not the two-stream format (corr 1.0).
const mixed = wav.channels < 2 || (() => {
  let same = 0, n = 0;
  for (let i = 0; i < wav.user.length; i += 97) {
    n++;
    if (Math.abs(wav.user[i] - wav.agent[i]) < 1e-6) same++;
  }
  return same > n * 0.99;
})();
const user = resample(wav.user, wav.rate);
const agent = mixed ? new Array(user.length).fill(0) : resample(wav.agent, wav.rate);
const th = { ...DEFAULT_THRESHOLDS, ...thresholds };

const bundle = loadBundle();
const enc = await ort.InferenceSession.create(bundle.encoderPath);
const step = await ort.InferenceSession.create(bundle.stepPath);
const engine = new TygerEngine(enc, step);
const sess = new TurnSession(thresholds);

const decisions = [];   // {frame, t, kind, fired, marginKey, value, thr}
const frames = [];      // per-frame scores for the trace/json
const heads = {
  p_end: { max: 0, at: -1, thr: th.ep_thr },
  yield: { max: 0, at: -1, thr: th.barge_thr },
  bc: { max: 0, at: -1, thr: th.bc_thr },
};
let frame = 0;
let speaking = false; // speaking episode with hysteresis (6 quiet hops to release)
let quietHops = 0;
const nHops = Math.floor(Math.min(user.length, agent.length) / HOP_N);
for (let h = 0; h < nHops; h++) {
  const x = (h + 1) * HOP_N;
  const hopU = user.slice(x - HOP_N, x);
  const hopA = agent.slice(x - HOP_N, x);
  const reset = sess.begin_hop(hopU, hopA, "listen"); // mode set below
  if (reset) engine.reset();
  let mode = "listen";
  if (!mixed) {
    const agentLoud = frameEnergy(hopA).some((e) => e > -50);
    if (agentLoud) { speaking = true; quietHops = 0; }
    else if (speaking && ++quietHops > 6) { speaking = false; quietHops = 0; }
    mode = speaking ? "speaking" : "listen";
  }
  sess.switch_mode(mode);
  const act = frameEnergy(engine.winU);
  await engine.hop(hopU, hopA, sess.prev_state, (out8, _i, actDb, left) => {
    frame++;
    const t = frame * 0.08;
    frames.push({ frame, t, mode, out: out8.map((v) => +v.toFixed(4)) });
    const vals = { p_end: out8[7], yield: out8[5], bc: out8[6] };
    for (const [k, v] of Object.entries(vals)) {
      if (v > heads[k].max) { heads[k].max = v; heads[k].at = t; }
    }
    const { events } = sess.on_frame(mode, out8, actDb, left);
    for (const e of events) {
      if (e.kind === "FRAME") continue;
      const key = e.kind === "ENDPOINT" ? "p_end" : e.kind === "BARGE" ? "yield" : "bc";
      const fired = e[key] ?? vals[key];
      decisions.push({ t: +t.toFixed(2), kind: e.kind, frame, value: +fired.toFixed(3), thr: heads[key].thr, margin: +(fired - heads[key].thr).toFixed(3) });
    }
    return sess.prev_state;
  });
}

const dur = (nHops * HOP_N / SR).toFixed(1);
console.log(`voice-agent-trainer: ${wavPath.split("/").pop()}  ${Math.floor(dur / 60)}:${String(Math.round(dur % 60)).padStart(2, "0")}  ` +
  `(${mixed ? "MIX: no agent stream — mode stays listen, agent turns look like caller turns" : "mic + agent streams"}, ${wav.rate} Hz)`);
console.log(`thresholds: ep ${th.ep_thr}/${th.ep_deb}  barge ${th.barge_thr}/${th.barge_deb}  bc ${th.bc_thr}/${th.bc_deb}  refractory ${th.bc_refractory}`);
console.log(`\ndecisions (${decisions.length}):`);
for (const d of decisions) {
  const mm = String(Math.floor(d.t / 60)).padStart(2, "0");
  console.log(`  ${mm}:${(d.t % 60).toFixed(1).padStart(4, "0")}  ${d.kind.padEnd(12)} ${d.kind === "ENDPOINT" ? "p_end" : d.kind === "BARGE" ? "yield" : "bc"}=${d.value}  (thr ${d.thr}, ${d.margin >= 0 ? "+" : ""}${d.margin})`);
}
console.log("\nclosest non-firing approaches (why nothing fired):");
for (const [k, v] of Object.entries(heads)) {
  const mm = String(Math.floor(v.at / 60)).padStart(2, "0");
  console.log(`  ${k.padEnd(6)} max ${v.max.toFixed(3)} vs thr ${v.thr}  gap ${(v.thr - v.max).toFixed(3)}${v.at >= 0 ? `  at ${mm}:${(v.at % 60).toFixed(1)}` : ""}`);
}

// 100-column traces of the three decision heads against their thresholds.
if (!quiet) {
  const cols = 100;
  const per = Math.max(1, Math.floor(frames.length / cols));
  for (const [k, v] of Object.entries(heads)) {
    const line = [];
    for (let c = 0; c < cols; c++) {
      const slice = frames.slice(c * per, (c + 1) * per);
      const m = slice.reduce((a, f) => Math.max(a, f.out[k === "p_end" ? 7 : k === "yield" ? 5 : 6]), 0);
      line.push(m >= v.thr ? "█" : m > v.thr * 0.9 ? "▇" : m > v.thr * 0.7 ? "▆" : m > v.thr * 0.5 ? "▄" : m > v.thr * 0.25 ? "▂" : "▁");
    }
    console.log(`\n${k} vs ${v.thr} (${per} frames/col):\n${line.join("")}`);
  }
}

if (jsonOut) {
  writeFileSync(jsonOut, JSON.stringify({ file: wavPath, thresholds: th, decisions, frames }));
  console.log(`\nwrote ${jsonOut} (${frames.length} frames)`);
}
