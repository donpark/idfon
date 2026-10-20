// Decision parity: replay crates/idfon-voice/tests/data/turns-fixtures.json
// (generated from tyger-s2s's rules.py by scripts/tyger-rules-fixtures.py) through
// the TS port, byte-identical to what the Rust port asserts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { TurnSession, type Event } from "../src/tyger/rules.ts";

const cases = JSON.parse(readFileSync(
  new URL("../../../crates/idfon-voice/tests/data/turns-fixtures.json", import.meta.url), "utf8"));

const norm = (e: Event) => JSON.parse(JSON.stringify(e));

test("rules fixtures match the python oracle", () => {
  assert.ok(cases.length > 0);
  for (const c of cases) {
    const sess = new TurnSession(c.th ?? {});
    const exp = c.expected;
    for (let h = 0; h < c.hops.length; h++) {
      const hop = c.hops[h];
      const mode = hop.mode ?? "";
      if (hop.set_words !== undefined) sess.words = hop.set_words;
      const user = new Array(5120).fill(hop.level ?? 0.1);
      const agent = new Array(5120).fill(hop.agent_level ?? 0.0);
      const hr = sess.begin_hop(user, agent, mode);
      const mr = sess.switch_mode(mode);
      const wv = sess.words_event(mode);
      assert.equal(hr, exp.hop_reset[h], `${c.name} hop ${h} begin_hop`);
      assert.equal(mr, exp.mode_changed[h], `${c.name} hop ${h} switch_mode`);
      if (exp.words_events[h] == null) {
        assert.equal(wv, null, `${c.name} hop ${h} words_event`);
      } else {
        assert.deepEqual(norm(wv!), exp.words_events[h], `${c.name} hop ${h} words_event`);
      }
      for (let i = 0; i < hop.frames.length; i++) {
        const [out, actDb] = hop.frames[i];
        const left = hop.frames.length - 1 - i;
        const { events, final, reset } = sess.on_frame(mode, out, actDb, left);
        const rec = exp.frame_records[h][i];
        assert.equal(reset, rec.reset, `${c.name} hop ${h} frame ${i} reset`);
        assert.deepEqual(events.map(norm), rec.events.map(norm), `${c.name} hop ${h} frame ${i} events`);
        if (final) {
          assert.equal(final.audio.length, rec.final_turn_len, `${c.name} hop ${h} frame ${i} final len`);
        } else {
          assert.equal(rec.final_turn_len, null, `${c.name} hop ${h} frame ${i} unexpected final`);
        }
      }
    }
  }
});
