// The endpointer glue: chunk -> resample -> hop accumulation -> rules events,
// driven by a stub engine (the model itself is gated by the parity runs; this
// pins the wiring: rates, hop pairing, event mapping, mode/reset plumbing).
import { test } from "node:test";
import assert from "node:assert/strict";
import { TygerEndpointer } from "../src/tyger/endpointer.ts";
import { TurnSession } from "../src/tyger/rules.ts";

/// Drives the rules to a fast ENDPOINT: p_end = 1, everything else quiet.
const stubEngine = () => {
  const hops: number[] = [];
  return {
    hops,
    winU: [] as number[],
    resetCalled: 0,
    reset() {
      this.resetCalled++;
    },
    async hop(_userHop: ArrayLike<number>, _agentHop: ArrayLike<number>, _prev: number, onFrame?: CallableFunction) {
      hops.push(1);
      let state = 0;
      for (let i = 0; i < 4; i++) {
        const out8 = [0, 0, 0, 0, 0.1, 0.1, 0.1, 1.0];
        if (onFrame) state = onFrame(out8, i, -20, 3 - i); // actDb -20 = voiced
      }
      return [];
    },
  };
};

test("endpoint fires through the glue and hops accumulate at 16k", async () => {
  const engine = stubEngine();
  const ep = new TygerEndpointer(engine as never, new TurnSession());
  const chunk = new Uint8Array(2400); // 50 ms at 24 kHz s16
  const view = new DataView(chunk.buffer);
  for (let i = 0; i < chunk.length / 2; i++) view.setInt16(i * 2, 8000, true); // voiced

  let events: string[] = [];
  // 50 ms chunks; ENDPOINT needs 8 frames = 2 hops (640 ms at 16 kHz)
  for (let i = 0; i < 20 && !events.length; i++) {
    events = await ep.push(chunk);
  }
  assert.ok(engine.hops.length >= 1, `hops: ${engine.hops.length}`);
  assert.deepEqual(events, ["endpoint"], `events: ${events}`);
});

test("endpoint survives a turn reset (second turn fires again)", async () => {
  const engine = stubEngine();
  const ep = new TygerEndpointer(engine as never, new TurnSession());
  const chunk = new Uint8Array(2400);
  const view = new DataView(chunk.buffer);
  for (let i = 0; i < chunk.length / 2; i++) view.setInt16(i * 2, 8000, true);

  const seen: string[] = [];
  for (let turn = 0; turn < 2; turn++) {
    for (let i = 0; i < 20; i++) {
      const evs = await ep.push(chunk);
      if (evs.length) {
        seen.push(...evs);
        break;
      }
    }
  }
  assert.deepEqual(seen, ["endpoint", "endpoint"], `events: ${seen}`);
  assert.ok(engine.resetCalled >= 1, "reset plumbs to the engine");
});
