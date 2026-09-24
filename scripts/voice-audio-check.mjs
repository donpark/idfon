#!/usr/bin/env node
// Self-check for the ai-voice-chat audio plumbing (no network):
//   Ogg Opus bytes -> toPcm24k -> wavWrap
// Generates a 2-second sine via ffmpeg, round-trips it through the pipeline,
// asserts duration, sample rate, and WAV structure.
//   Usage: node scripts/check-voice-audio.mjs [path/to/recording.opus]
// Without ffmpeg, pass an existing .opus file as the only argument.
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

// resolve deps from the agent app (ogg-opus-decoder lives in its node_modules)
const agentRoot = fileURLToPath(new URL("../agents/ai-voice-chat/", import.meta.url));
const require = createRequire(join(agentRoot, "package.json"));
const { OggOpusDecoder } = require("ogg-opus-decoder");

const RATE = 24_000;
const work = mkdtempSync(join(tmpdir(), "voice-check."));

// --- pipeline under test (mirrors agent/tools/voice-reply.ts; keep in sync) ---
async function toPcm24k(opusBytes) {
  const decoder = new OggOpusDecoder();
  await decoder.ready;
  const decoded = await decoder.decodeFile(Buffer.from(opusBytes));
  await decoder.free();
  if (decoded.samplesDecoded === 0) throw new Error("no audio decoded");
  const samples = decoded.channelData[0];
  const out = Buffer.alloc(Math.ceil(samples.length / 2) * 2);
  for (let i = 0, j = 0; i + 1 < samples.length; i += 2, j += 1) {
    const v = (samples[i] + samples[i + 1]) / 2;
    out.writeInt16LE(Math.round(Math.max(-1, Math.min(1, v)) * 32767), j * 2);
  }
  return out;
}
function wavWrap(pcm) {
  const h = Buffer.alloc(44);
  h.write("RIFF", 0); h.writeUInt32LE(36 + pcm.length, 4); h.write("WAVE", 8);
  h.write("fmt ", 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20);
  h.writeUInt16LE(1, 22); h.writeUInt32LE(RATE, 24); h.writeUInt32LE(RATE * 2, 28);
  h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write("data", 36);
  h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
}
// -----------------------------------------------------------------------------

let opusPath = process.argv[2];
let opusBytes;
if (!opusPath) {
  const wav = join(work, "in.wav");
  const opusOgg = join(work, "in.opus");
  const pcmRaw = join(work, "in.pcm");
  const seconds = 2;
  // 2 s of 440 Hz sine at 48 kHz mono s16le, then to Ogg Opus
  const samples = new Int16Array(48_000 * seconds);
  for (let i = 0; i < samples.length; i += 1) {
    samples[i] = Math.round(Math.sin((2 * Math.PI * 440 * i) / 48_000) * 8000);
  }
  writeFileSync(pcmRaw, Buffer.from(samples.buffer));
  execFileSync("ffmpeg", ["-y", "-f", "s16le", "-ar", "48000", "-ac", "1", "-i", pcmRaw, "-c:a", "libopus", "-f", "ogg", opusOgg], { stdio: "pipe" });
  opusBytes = readFileSync(opusOgg);
} else {
  opusBytes = readFileSync(opusBytes);
}

try {
  const pcm = await toPcm24k(opusBytes);
  const wav = wavWrap(pcm);

  const durationSec = pcm.length / (RATE * 2);
  const inputSamples = 48_000 * 2; // what ffmpeg encoded (2 s)
  const expect = inputSamples / 2 / RATE;
  if (Math.abs(durationSec - expect) > 0.05) {
    throw new Error(`duration mismatch: got ${durationSec.toFixed(3)}s, want ~${expect}s`);
  }
  if (wav.readUInt32LE(24) !== RATE) throw new Error("wav sample rate wrong");
  if (wav.length !== 44 + pcm.length) throw new Error("wav length wrong");
  // non-silence sanity
  let peak = 0;
  for (let i = 0; i < pcm.length; i += 2) peak = Math.max(peak, Math.abs(pcm.readInt16LE(i)));
  if (peak < 1000) throw new Error(`output is silent (peak ${peak})`);
  console.log(`PASS: ${durationSec.toFixed(2)}s @24kHz mono s16le, wav ${wav.length} bytes, peak ${peak}`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
