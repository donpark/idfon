// The per-call observation record (src/observe/): fixture-built calls assert
// the emitted record shape, the habit stat values, and the friction joins.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { CallRecorder, EARLY_HANGUP_MS, EARLY_HANGUP_TURNS } from "../src/observe/collector.ts";
import { appendCallRecord } from "../src/observe/emitter.ts";
import type { CallRecord } from "../src/observe/schema.ts";

const HOW_NULLS = { emotion: null, sarcasm: null, delivery: null };

test("record shape carries the reserved paralinguistic slot as nulls", () => {
  const rec = new CallRecorder("call-x", new Date(1_700_000_000_000));
  rec.addTurn({ text: "hi there", role: "user", started_ms: 0, duration_ms: 900 });
  rec.addTurn({ text: "Hello!", role: "agent", started_ms: 1_000, duration_ms: 500 });
  const record = rec.build(new Date(1_700_000_600_000));
  assert.equal(record.schema, "eve-idfon-voice.call-observe/1");
  assert.equal(record.call_id, "call-x");
  assert.equal(record.started_at, "2023-11-14T22:13:20.000Z");
  assert.equal(record.duration_ms, 600_000);
  assert.equal(record.turn_count, 2);
  assert.deepEqual(record.turns, [
    { text: "hi there", role: "user", started_ms: 0, duration_ms: 900, how: HOW_NULLS },
    { text: "Hello!", role: "agent", started_ms: 1_000, duration_ms: 500, how: HOW_NULLS },
  ]);
  // every how field must be able to carry annotation strings later: null now
  for (const turn of record.turns) assert.deepEqual(turn.how, HOW_NULLS);
});

test("user habit stats: turn duration percentiles and words-per-turn median", () => {
  const rec = new CallRecorder("call-stats", new Date(0));
  rec.addTurn({ text: "one two three", role: "user", started_ms: 0, duration_ms: 1000 }); // 3 words
  rec.addTurn({ text: "a b", role: "user", started_ms: 2000, duration_ms: 2000 }); // 2
  rec.addTurn({ text: "w w w w", role: "user", started_ms: 4000, duration_ms: 3000 }); // 4
  rec.addTurn({ text: "five words in here now", role: "user", started_ms: 6000, duration_ms: 4000 }); // 5
  const record = rec.build(new Date(120_000));
  assert.deepEqual(record.user.turn_duration_ms, { p50: 2000, p90: 4000 });
  assert.equal(record.user.words_per_turn_p50, 3); // sorted [2,3,4,5], nearest-rank
});

test("interjection rate counts user turns starting during agent delivery", () => {
  const rec = new CallRecorder("call-interject", new Date(0));
  rec.addTurn({ text: "well actually never mind", role: "agent", started_ms: 1000, duration_ms: 2000 });
  rec.addTurn({ text: "mm-hmm", role: "user", started_ms: 1500, duration_ms: 400 }); // over the agent
  rec.addTurn({ text: "go on", role: "user", started_ms: 3500, duration_ms: 500 }); // after delivery
  const record = rec.build(new Date(60_000));
  assert.equal(record.user.interjection_rate, 0.5);
});

test("backchannel and repair heuristics label user turns", () => {
  const rec = new CallRecorder("call-labels", new Date(0));
  rec.addTurn({ text: "mm-hmm", role: "user", started_ms: 0, duration_ms: 300 });
  rec.addTurn({ text: "yeah", role: "user", started_ms: 1000, duration_ms: 300 });
  rec.addTurn({ text: "wait, what do you mean?", role: "user", started_ms: 2000, duration_ms: 700 });
  rec.addTurn({ text: "turn right at the light and keep going", role: "user", started_ms: 3000, duration_ms: 2000 });
  rec.addTurn({ text: "huh", role: "user", started_ms: 5000, duration_ms: 300 });
  const record = rec.build(new Date(60_000));
  assert.equal(record.user.backchannels, 2);
  assert.equal(record.user.repairs, 2); // "wait, what do you mean?" + "huh"
  assert.equal(record.user.backchannel_ratio, 0.5);
});

test("friction: re-asks join similar user turns ~3 turns apart", () => {
  const rec = new CallRecorder("call-reask", new Date(0));
  rec.addTurn({ text: "what time does the museum close tomorrow", role: "user", started_ms: 0, duration_ms: 2000 });
  rec.addTurn({ text: "At six.", role: "agent", started_ms: 2500, duration_ms: 500 });
  rec.addTurn({ text: "how about on weekends", role: "user", started_ms: 4000, duration_ms: 1200 });
  rec.addTurn({ text: "Same hours.", role: "agent", started_ms: 5500, duration_ms: 500 });
  rec.addTurn({ text: "what time does the museum close tomorrow", role: "user", started_ms: 7000, duration_ms: 2000 });
  rec.addTurn({ text: "At six.", role: "agent", started_ms: 9500, duration_ms: 500 });
  rec.addTurn({ text: "and weekends, what time does it close", role: "user", started_ms: 11000, duration_ms: 1800 });
  const record = rec.build(new Date(60_000));
  assert.deepEqual(record.friction, [
    { type: "reask", turn_index: 4, excerpt: "what time does the museum close tomorrow" },
  ]);
});

test("friction: repair initiator and barge-in-then-restart join", () => {
  const rec = new CallRecorder("call-friction", new Date(0));
  rec.addTurn({ text: "hello", role: "user", started_ms: 0, duration_ms: 500 });
  rec.addTurn({ text: "Hi! The answer is forty two.", role: "agent", started_ms: 1000, duration_ms: 3000 });
  rec.recordPlaybackTruncated(2500); // barge-in cut the agent playback
  rec.addTurn({ text: "wait, what do you mean", role: "user", started_ms: 3000, duration_ms: 800 });
  rec.addTurn({ text: "Let me explain again.", role: "agent", started_ms: 4000, duration_ms: 2000 });
  const record = rec.build(new Date(60_000));
  assert.deepEqual(record.friction, [
    { type: "barge_restart", turn_index: 2, excerpt: "wait, what do you mean" },
    { type: "repair", turn_index: 2, excerpt: "wait, what do you mean" },
  ]);
});

test("friction: early hangup trips on turn count or duration", () => {
  const short = new CallRecorder("call-short", new Date(0));
  short.addTurn({ text: "hi", role: "user", started_ms: 0, duration_ms: 300 });
  short.addTurn({ text: "hello", role: "agent", started_ms: 400, duration_ms: 600 });
  // 2 turns (< EARLY_HANGUP_TURNS) and 20 s (< EARLY_HANGUP_MS): trips both
  const record = short.build(new Date(20_000));
  assert.deepEqual(record.friction, [{ type: "early_hangup", turn_index: 1, excerpt: "" }]);

  const fewTurns = new CallRecorder("call-long-but-few", new Date(0));
  fewTurns.addTurn({ text: "hi", role: "user", started_ms: 0, duration_ms: 300 });
  fewTurns.addTurn({ text: "hello", role: "agent", started_ms: 400, duration_ms: 600 });
  assert.ok(fewTurns.build(new Date(EARLY_HANGUP_MS * 10)).friction.some((f) => f.type === "early_hangup"));

  const fine = new CallRecorder("call-fine", new Date(0));
  for (let i = 0; i < EARLY_HANGUP_TURNS; i++) {
    fine.addTurn({ text: `turn ${i}`, role: i % 2 ? "agent" : "user", started_ms: i * 1000, duration_ms: 500 });
  }
  assert.deepEqual(fine.build(new Date(EARLY_HANGUP_MS * 2)).friction, []);
});

test("emitter appends one JSONL line per call", () => {
  const rec = new CallRecorder("call-jsonl", new Date(0));
  rec.addTurn({ text: "hi", role: "user", started_ms: 0, duration_ms: 300 });
  const first: CallRecord = rec.build(new Date(60_000));
  const second: CallRecord = new CallRecorder("call-jsonl-2", new Date(0)).build(new Date(60_000));
  const path = join(mkdtempSync(join(tmpdir(), "observe-")), "calls.jsonl");
  appendCallRecord(path, first);
  appendCallRecord(path, second);
  const lines = readFileSync(path, "utf8").trim().split("\n");
  assert.equal(lines.length, 2);
  assert.deepEqual(JSON.parse(lines[0]), first);
  assert.deepEqual(JSON.parse(lines[1]), second);
});

test("bcd block is null when the detector never ran", () => {
  const rec = new CallRecorder("call-nobcd", new Date(0));
  rec.addTurn({ text: "hi", role: "user", started_ms: 0, duration_ms: 300 });
  assert.equal(rec.build(new Date(60_000)).bcd, null);
});

test("latency ledger: per-turn delays and their percentiles", () => {
  const rec = new CallRecorder("call-latency", new Date(0));
  // Two user turns, each followed by an agent turn. The ledger points at the
  // user turn's index in turns[] and carries the waiting-time gaps.
  const u1 = rec.addTurn({ text: "first", role: "user", started_ms: 10_000, duration_ms: 800 });
  rec.addTurn({ text: "One.", role: "agent", started_ms: 12_000, duration_ms: 900 });
  const u2 = rec.addTurn({ text: "second", role: "user", started_ms: 20_000, duration_ms: 700 });
  rec.addTurn({ text: "Two.", role: "agent", started_ms: 22_000, duration_ms: 900 });
  rec.recordLatency({
    turn_index: u1, caller_stop_ms: 10_800, endpoint_ms: 11_600, decision_ms: 800,
    endpoint_source: "energy", queue_ms: 40, stt_ms: 300, reply_ms: 900, agent_ms: 720,
    tts_ttfb_ms: 220, tts_ms: 1_200, play_ms: 80, heard_ms: 1_460, frame_ms: 25,
  });
  rec.recordLatency({
    turn_index: u2, caller_stop_ms: 20_700, endpoint_ms: 20_760, decision_ms: 60,
    endpoint_source: "tyger", queue_ms: 10, stt_ms: 250, reply_ms: 700, agent_ms: 560,
    tts_ttfb_ms: 180, tts_ms: 1_000, play_ms: 70, heard_ms: 1_190, frame_ms: 25,
  });
  rec.recordFramePush(20);
  rec.recordFramePush(30);
  const latency = rec.build(new Date(60_000)).latency;
  assert.equal(latency.turns.length, 2);
  assert.equal(latency.turns[0].turn_index, u1);
  assert.equal(latency.turns[0].decision_ms, 800);
  assert.equal(latency.turns[0].heard_ms, 1_460);
  assert.equal(latency.turns[0].agent_ms, 720); // the agent's generation, bridge-reported
  assert.deepEqual(latency.decision_ms, { p50: 60, p90: 800 }); // nearest-rank, 2 values
  assert.deepEqual(latency.heard_ms, { p50: 1_190, p90: 1_460 });
  assert.deepEqual(latency.agent_ms, { p50: 560, p90: 720 });
  assert.deepEqual(latency.endpoint_sources, { tyger: 1, energy: 1 });
  assert.equal(latency.frame_ms, 25); // mean of 20 and 30
});

test("latency ledger: a turn with no audio yet reports nulls, not zeros", () => {
  const rec = new CallRecorder("call-noaudio", new Date(0));
  const u = rec.addTurn({ text: "hi", role: "user", started_ms: 1_000, duration_ms: 300 });
  rec.recordLatency({
    turn_index: u, caller_stop_ms: 1_300, endpoint_ms: 2_100, decision_ms: 800,
    endpoint_source: "energy", queue_ms: 0, stt_ms: 300, reply_ms: 500, agent_ms: null,
    tts_ttfb_ms: null, tts_ms: 0, play_ms: 0, heard_ms: null, frame_ms: 0,
  });
  const latency = rec.build(new Date(60_000)).latency;
  assert.deepEqual(latency.tts_ttfb_ms, { p50: 0, p90: 0 }); // empty set
  assert.deepEqual(latency.heard_ms, { p50: 0, p90: 0 });
  assert.deepEqual(latency.agent_ms, { p50: 0, p90: 0 }); // nulls excluded
});

test("bcd events land as counts and raw events", () => {
  const rec = new CallRecorder("call-bcd", new Date(0));
  rec.markBcdActive();
  rec.recordBcdEvent("backchannel", 52_100, 0.83);
  rec.recordBcdEvent("floor_take", 61_000, 0.91);
  rec.recordBcdEvent("backchannel", 70_000, 0.77);
  const bcd = rec.build(new Date(90_000)).bcd;
  assert.ok(bcd);
  assert.equal(bcd.backchannels, 2);
  assert.equal(bcd.floor_takes, 1);
  assert.deepEqual(bcd.events, [
    { kind: "backchannel", at_ms: 52_100, p: 0.83 },
    { kind: "floor_take", at_ms: 61_000, p: 0.91 },
    { kind: "backchannel", at_ms: 70_000, p: 0.77 },
  ]);
});
