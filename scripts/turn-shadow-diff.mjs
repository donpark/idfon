#!/usr/bin/env node
// Turn-shadow decision diff: compare the turn model's decisions against the
// turns the session actually committed, from a pulled app log. This is the P3
// gate (`docs/voice-tyger-option.md`): how often would the model's ENDPOINT
// have committed the same turn as the classic Segmenter?
//
//   node turn-shadow-diff.mjs <app-log>            # iOS: devicectl copy from …
//   node turn-shadow-diff.mjs --selftest
//
// Reads `idfon-auto:` lines: `turn-shadow: <KIND> …`, `voice-agent: heard=…`
// (classic commits), `turn-taker: tyger endpoint -> commit` (model-driven
// commits). Events within --tol (default 1.5 s) pair as one turn.
import { readFileSync } from "node:fs";

const args = process.argv.slice(2);
const selftest = args.includes("--selftest");
const tol = Number(args[args.indexOf("--tol") + 1]) || 1.5;

/// -> { shadow: [{t, kind}], commits: [{t, model: bool}] }
function parse(lines) {
  const shadow = [];
  const commits = [];
  let modelCommit = false; // the turn-taker: tyger endpoint -> commit mark
  let modelTrace = null;   // the per-turn trace line (turn-taker: classic|tyger)
  for (const line of lines) {
    const m = /^(\S+Z)\s+\S+:\s+(.*)$/.exec(line);
    if (!m) continue;
    const t = Date.parse(m[1]);
    const body = m[2];
    const s = /^turn-shadow: (\w+)/.exec(body);
    if (s) {
      shadow.push({ t, kind: s[1] });
      continue;
    }
    const trace = /^turn-taker: (classic|tyger)$/.exec(body);
    if (trace) { modelTrace = trace[1] === "tyger"; continue; }
    if (/^turn-taker: tyger endpoint/.test(body)) modelCommit = true;
    const heard = /^voice-agent: heard=/.test(body);
    if (heard) {
      commits.push({ t, model: modelTrace ?? modelCommit });
      modelCommit = false;
      modelTrace = null;
    }
  }
  return { shadow, commits };
}

/// Same-kind/turn events within tol = one turn (greedy earliest, parity7 style).
function diff(shadow, commits, tolMs) {
  const used = new Set();
  let matched = 0;
  const onlyShadow = [];
  for (const e of shadow.filter((x) => x.kind === "ENDPOINT")) {
    let best = -1;
    for (let i = 0; i < commits.length; i++) {
      if (used.has(i)) continue;
      const d = Math.abs(commits[i].t - e.t);
      if (d <= tolMs && (best < 0 || d < Math.abs(commits[best].t - e.t))) best = i;
    }
    if (best >= 0) {
      used.add(best);
      matched++;
    } else {
      onlyShadow.push(e);
    }
  }
  const onlyCommit = commits.filter((_, i) => !used.has(i));
  return { matched, onlyShadow, onlyCommit };
}

function report(lines) {
  const { shadow, commits } = parse(lines);
  const ends = shadow.filter((e) => e.kind === "ENDPOINT").length;
  const { matched, onlyShadow, onlyCommit } = diff(shadow, commits, tol * 1000);
  const denom = Math.max(ends, commits.length);
  console.log(`shadow decisions: ${shadow.length} (${ends} ENDPOINT, ${shadow.filter((e) => e.kind === "BACKCHANNEL").length} BACKCHANNEL, ${shadow.filter((e) => e.kind === "BARGE").length} BARGE)`);
  console.log(`committed turns:  ${commits.length} (${commits.filter((c) => c.model).length} model-driven)`);
  console.log(`agreement (±${tol}s): ${(denom ? (100 * matched) / denom : 0).toFixed(1)}%  (${matched}/${denom})`);
  console.log(`model-only endpoints: ${onlyShadow.length}  classic-only commits: ${onlyCommit.length}`);
  for (const e of onlyShadow.slice(0, 8)) console.log(`  + model  ${new Date(e.t).toISOString()} ${e.kind}`);
  for (const c of onlyCommit.slice(0, 8)) console.log(`  + classic ${new Date(c.t).toISOString()}`);
}

if (selftest) {
  const t0 = Date.parse("2026-10-20T12:00:00Z");
  const iso = (ms) => new Date(t0 + ms).toISOString().replace(".000Z", "Z");
  const lines = [
    `${iso(0)} idfon-auto: turn-shadow: ENDPOINT frame=12 turn_s=1.20 onset_s=-`,
    `${iso(200)} idfon-auto: voice-agent: heard=hello`,
    `${iso(30000)} idfon-auto: turn-shadow: ENDPOINT frame=40 turn_s=3.20 onset_s=-`,
    `${iso(60000)} idfon-auto: voice-agent: heard=late`,
  ];
  const { shadow, commits } = parse(lines);
  const { matched, onlyShadow, onlyCommit } = diff(shadow, commits, 1500);
  const pass = matched === 1 && onlyShadow.length === 1 && onlyCommit.length === 1;
  console.log(`selftest: matched=${matched} onlyShadow=${onlyShadow.length} onlyCommit=${onlyCommit.length} -> ${pass ? "PASS" : "FAIL"}`);
  process.exit(pass ? 0 : 1);
}

report(readFileSync(args.find((a) => !a.startsWith("--")), "utf8").split("\n"));
