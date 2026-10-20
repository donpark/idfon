// Mel parity: the TS port computes the Python extractor's features within the
// Swift port's accepted tolerance (≤2e-3) on the same scripted audio.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { process } from "../src/tyger/mel.ts";

const fixtures = JSON.parse(readFileSync(
  new URL("../../../ports/tyger-swift/Tests/TygerVoiceTests/fixtures.json", import.meta.url), "utf8"));

const TOL = 2e-3;

test("mel features match the python extractor", () => {
  for (const c of fixtures.cases) {
    const { features, validFrames } = process(c.audio);
    assert.equal(validFrames, c.valid, `${c.name} valid frames`);
    assert.equal(features.length, Math.floor(c.audio.length / 160) + 1, `${c.name} frame count`);
    for (let i = 0; i < c.sample_idx.length; i++) {
      const got = features[c.sample_idx[i]];
      const want = c.frames[i];
      for (let m = 0; m < want.length; m++) {
        assert.ok(
          Math.abs(got[m] - want[m]) <= TOL,
          `${c.name} frame ${c.sample_idx[i]} mel ${m}: got ${got[m]} want ${want[m]}`,
        );
      }
    }
  }
});
