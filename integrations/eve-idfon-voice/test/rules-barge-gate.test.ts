// Barge audibility gate and refractory (docs/voice-decision-model.md, 2026-11-06
// barge event spec), the TS port's half of crates/idfon-voice/tests/turns_barge_gate.rs.
// Both conditions default to off so the fixture parity test still asserts tyger-s2s.
import { test } from "node:test";
import assert from "node:assert/strict";
import { TurnSession, type Thresholds } from "../src/tyger/rules.ts";

const HOP_N = 5120;          // 320 ms at 16 kHz
const FRAMES_PER_HOP = 4;
const out = (yp: number) => [0, 0, 2, 0, 0, yp, 0, 0];   // loud yield head, SPEAK-ish state

/** Drive `hops` hops in `mode`; returns the frame indices that emitted BARGE. */
function drive(sess: TurnSession, mode: string, hops: number, userRms: number, agentRms: number, yp: number) {
  const fired: number[] = [];
  let n = 0;
  for (let h = 0; h < hops; h++) {
    sess.begin_hop(new Array(HOP_N).fill(userRms), new Array(HOP_N).fill(agentRms), mode);
    for (let i = 0; i < FRAMES_PER_HOP; i++) {
      const { events } = sess.on_frame(mode, out(yp), -20, FRAMES_PER_HOP - 1 - i);
      if (events.some((e) => e.kind === "BARGE")) fired.push(n);
      n += 1;
    }
  }
  return fired;
}

test("gate off by default: the yield run alone fires", () => {
  const s = new TurnSession({});
  s.switch_mode("speaking");
  assert.ok(drive(s, "speaking", 3, 0.1, 0.0, 0.9).length > 0);
});

test("audibility gate blocks the release tail but allows a real overlap", () => {
  const th: Thresholds = { barge_gate_db: -50 };
  const tail = new TurnSession(th);
  tail.switch_mode("speaking");
  assert.deepEqual(drive(tail, "speaking", 3, 0.1, 0.0, 0.9), [], "silent agent channel");

  const live = new TurnSession(th);
  live.switch_mode("speaking");
  assert.ok(drive(live, "speaking", 3, 0.1, 0.1, 0.9).length > 0);
});

test("refractory allows one barge per speaking episode", () => {
  const s = new TurnSession({ barge_refractory: 1 });
  s.switch_mode("speaking");
  assert.equal(drive(s, "speaking", 4, 0.1, 0.1, 0.9).length, 1);
  s.switch_mode("listen");
  drive(s, "listen", 1, 0.0, 0.0, 0.0);
  s.switch_mode("speaking");
  assert.equal(drive(s, "speaking", 3, 0.1, 0.1, 0.9).length, 1);
});

test("gate does not fire below the yield threshold", () => {
  const s = new TurnSession({ barge_gate_db: -50 });
  s.switch_mode("speaking");
  assert.deepEqual(drive(s, "speaking", 3, 0.1, 0.1, 0.1), []);
});

test("edge trigger fires once per crossing, and re-arms after a dip", () => {
  const s = new TurnSession({ barge_edge: true });
  s.switch_mode("speaking");
  assert.equal(drive(s, "speaking", 4, 0.1, 0.1, 0.9).length, 1);

  const t = new TurnSession({ barge_edge: true });
  t.switch_mode("speaking");
  drive(t, "speaking", 2, 0.1, 0.1, 0.9);
  drive(t, "speaking", 1, 0.1, 0.1, 0.1);
  assert.equal(drive(t, "speaking", 2, 0.1, 0.1, 0.9).length, 1);
});

test("edge trigger is off in the parity defaults", () => {
  const s = new TurnSession({});
  s.switch_mode("speaking");
  assert.ok(drive(s, "speaking", 4, 0.1, 0.1, 0.9).length > 1);
});
