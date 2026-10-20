// The language knob: tag resolution and prompt-id lookup.
import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveLanguage } from "../src/tyger/language.ts";

test("language tags resolve to ASR prompt ids", () => {
  assert.equal(resolveLanguage("en").asrPromptId, 0);
  assert.equal(resolveLanguage("ko-KR").asrPromptId, 14);
  assert.equal(resolveLanguage("ko").asrPromptId, 14);
  assert.equal(resolveLanguage("ja").asrPromptId, 10);
  assert.equal(resolveLanguage("de-DE").asrPromptId, 9);
  assert.equal(resolveLanguage("fr-CA").asrPromptId, 100);
});

test("unknown tags fall back to english", () => {
  assert.equal(resolveLanguage("xx-ZZ").asrPromptId, 0);
  assert.equal(resolveLanguage("xx-ZZ").tag, "xx-ZZ");
});

test("env drives resolution when no tag is passed", () => {
  process.env.IDFON_VOICE_LANG = "ko-KR";
  assert.equal(resolveLanguage().asrPromptId, 14);
  delete process.env.IDFON_VOICE_LANG;
  assert.equal(resolveLanguage().asrPromptId, 0);
});
