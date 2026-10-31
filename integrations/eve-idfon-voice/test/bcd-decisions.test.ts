// Decision-threshold logic on scripted score sequences: floor crossing 0.7
// fires floor_take once per crossing, backchannel fires only after user-stop
// and is dropped at the 1.2 s backstop. Hermetic — no model needed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { BcdDecisions, FRAME_S } from "../src/bcd/decisions.ts";

// intent softmax layout: [continuer, assessment, negative, floor_take, non_speech]
const NON_SPEECH = [0, 0, 0, 0, 1];
const BACKCHANNEL = [0.5, 0.3, 0, 0, 0.2]; // p(backchannel) = 0.8
const FLOOR = [0, 0, 0.4, 0.4, 0.2]; // p(floor) = 0.8

function run(
  frames: Array<{ intent: number[]; vad: number }>,
  thresholds = {},
): Array<{ kind: string; frame: number }> {
  const d = new BcdDecisions(thresholds);
  return frames.map((f) => d.onFrame(f.intent, f.vad));
}

test("floor crossing 0.7 fires floor_take once per crossing", () => {
  const frames = [
    ...Array(5).fill({ intent: NON_SPEECH, vad: 0.9 }),
    ...Array(5).fill({ intent: FLOOR, vad: 0.9 }), // crossing at frame 5
    ...Array(5).fill({ intent: NON_SPEECH, vad: 0.9 }),
    ...Array(5).fill({ intent: FLOOR, vad: 0.9 }), // second crossing at frame 15
  ];
  const events = run(frames);
  const fired = events.filter((e) => e.kind === "floor_take");
  assert.deepEqual(fired.map((e) => e.frame), [5, 15]);
});

test("backchannel fires only after user-stop", () => {
  const frames = [
    ...Array(3).fill({ intent: BACKCHANNEL, vad: 0.9 }), // crossing at 0, user talking
    ...Array(3).fill({ intent: NON_SPEECH, vad: 0.9 }), // still talking: no call
    { intent: NON_SPEECH, vad: 0.1 }, // user stops at frame 6
    ...Array(3).fill({ intent: NON_SPEECH, vad: 0.1 }),
  ];
  const events = run(frames);
  const fired = events.filter((e) => e.kind === "backchannel");
  assert.deepEqual(fired.map((e) => e.frame), [6]);
});

test("backchannel drops at the 1.2 s backstop if the user never stops", () => {
  const backstopFrames = Math.round(1.2 / FRAME_S); // 60
  const frames = [
    { intent: BACKCHANNEL, vad: 0.9 }, // crossing at frame 0
    // user talks through the backstop and beyond
    ...Array(backstopFrames + 10).fill({ intent: NON_SPEECH, vad: 0.9 }),
    { intent: NON_SPEECH, vad: 0.1 }, // user stops late: pending was dropped
  ];
  const events = run(frames);
  assert.equal(events.filter((e) => e.kind === "backchannel").length, 0);
});

test("backchannel fires at user-stop just inside the backstop", () => {
  const backstopFrames = Math.round(1.2 / FRAME_S); // 60
  const frames = [
    { intent: BACKCHANNEL, vad: 0.9 }, // crossing at frame 0
    ...Array(backstopFrames - 2).fill({ intent: NON_SPEECH, vad: 0.9 }),
    { intent: NON_SPEECH, vad: 0.1 }, // user stops at frame 59: inside
  ];
  const events = run(frames);
  const fired = events.filter((e) => e.kind === "backchannel");
  assert.deepEqual(fired.map((e) => e.frame), [backstopFrames - 1]);
});

test("floor crossing cancels a pending backchannel", () => {
  const frames = [
    { intent: BACKCHANNEL, vad: 0.9 }, // arm at 0
    ...Array(5).fill({ intent: NON_SPEECH, vad: 0.9 }),
    { intent: FLOOR, vad: 0.9 }, // floor_take at 6: pending backchannel gone
    ...Array(5).fill({ intent: NON_SPEECH, vad: 0.9 }),
    { intent: NON_SPEECH, vad: 0.1 }, // user stops at 12: nothing left to call
  ];
  const events = run(frames);
  assert.deepEqual(
    events.filter((e) => e.kind !== "none").map((e) => e.kind),
    ["floor_take"],
  );
});

test("backchannel fires immediately when the user is already stopped", () => {
  const frames = [
    { intent: NON_SPEECH, vad: 0.1 },
    { intent: BACKCHANNEL, vad: 0.1 }, // crossing at 1, no one speaking
  ];
  const events = run(frames);
  const fired = events.filter((e) => e.kind === "backchannel");
  assert.deepEqual(fired.map((e) => e.frame), [1]);
});

test("one crossing fires once even if p stays high", () => {
  const frames = [
    ...Array(10).fill({ intent: BACKCHANNEL, vad: 0.9 }), // stays above threshold
    { intent: NON_SPEECH, vad: 0.1 }, // one stop: one call
  ];
  const events = run(frames);
  assert.equal(events.filter((e) => e.kind === "backchannel").length, 1);
});
