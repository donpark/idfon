// Live-relay E2E without a phone: a fake bridge serves the SSE caller stream
// (synthetic speech from macOS `say`, 24 kHz), records what the relay posts
// back, and asserts the whole loop: tyger endpoint -> STT -> reply -> TTS.
//
//   node live-relay-e2e.mjs [--text "what the caller says"] [--lang ko-KR]
//
// PASS = one committed turn: transcript matches (fuzzy), reply audio posted.
import { execSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const relay = fileURLToPath(new URL("../../integrations/eve-idfon-voice/live-relay.mjs", import.meta.url));
const args = process.argv.slice(2);
const argOf = (f) => (args.includes(f) ? args[args.indexOf(f) + 1] : undefined);
const text = argOf("--text") ?? "Hello, this is a test of the tyger endpointer.";
const lang = argOf("--lang");

// --- caller audio: `say` at 24 kHz s16 + a 2 s quiet tail (the turn's end) ---
const dir = join(tmpdir(), `live-relay-e2e-${process.pid}`);
rmSync(dir, { recursive: true, force: true });
mkdirSync(dir, { recursive: true });
const aiff = join(dir, "c.aiff");
const wav = join(dir, "c.wav");
execSync(`say -v "Ava (Enhanced)" ${JSON.stringify(text)} -o ${JSON.stringify(aiff)}`);
execSync(`afconvert -f WAVE -d LEI16@24000 -c 1 ${JSON.stringify(aiff)} ${JSON.stringify(wav)}`);
const wavBuf = readFileSync(wav);
const speech = wavBuf.subarray(44); // s16le mono 24 kHz
const quiet = Buffer.alloc(24000 * 2 * 2); // 2 s of silence
const caller = Buffer.concat([speech, quiet]);

// --- fake bridge: SSE out, record in ---
const posted = [];
const server = createServer((req, res) => {
  if (req.url === "/live/stream") {
    res.writeHead(200, { "content-type": "text/event-stream" });
    // stream the caller audio in 100 ms frames
    let off = 0;
    const timer = setInterval(() => {
      if (off >= caller.length) {
        clearInterval(timer);
        return;
      }
      const chunk = caller.subarray(off, off + 4800);
      off += 4800;
      res.write(`data: ${JSON.stringify({ type: "audio.frame", peer_id: "e2e", pcm_base64: chunk.toString("base64") })}\n\n`);
    }, 25);
    req.on("close", () => clearInterval(timer));
    return;
  }
  if (req.method === "POST") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      posted.push({ url: req.url, body });
      res.writeHead(200, { "content-type": "application/json" });
      res.end("{}");
    });
    return;
  }
  res.writeHead(404);
  res.end();
});

await new Promise((r) => server.listen(0, "127.0.0.1", r));
const bridge = `http://127.0.0.1:${server.address().port}`;

// --- the relay under test ---
const child = spawn(process.execPath, [relay], {
  env: {
    ...process.env,
    IDFON_BRIDGE_URL: bridge,
    IDFON_BRIDGE_SECRET: "e2e",
    IDFON_VOICE_ENGINE: JSON.stringify({
      stt: { provider: "deepgram", api_key_env: "DEEPGRAM_API_KEY" },
      tts: { provider: "elevenlabs", voice: "EXAVITQu4vr4xnSDxMaL", api_key_env: "ELEVENLABS_API_KEY" },
    }), // real providers (the gateway serves neither /audio/transcriptions nor /audio/speech)
    ...(lang ? { IDFON_VOICE_LANG: lang } : {}),
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let log = "";
child.stderr.on("data", (c) => (log += c));
child.stdout.on("data", (c) => (log += c));

const deadline = Date.now() + 90_000;
while (Date.now() < deadline && !posted.some((p) => p.url === "/live/audio")) {
  await new Promise((r) => setTimeout(r, 500));
}
child.kill("SIGTERM");
server.close();

const heard = /"message":"heard","transcript":"([^"]*)"/.exec(log)?.[1] ?? "";
const audio = posted.filter((p) => p.url === "/live/audio");
const bytes = audio.reduce((n, p) => n + JSON.parse(p.body).pcm_base64.length * 0.75, 0);
console.log(`transcript: ${heard || "(none)"}`);
console.log(`reply audio: ${audio.length} posts, ${(bytes / 24000 / 2).toFixed(2)} s`);
const kind = /"message":"endpointer","kind":"([^"]*)"/.exec(log)?.[1] ?? "?";
console.log(`endpointer: ${kind}`);
const okKind = kind === "tyger";
// speech-tolerant: STT hears "tyger" as "tiger" and "endpointer" as two words
const flat = heard.toLowerCase().replace(/[^a-z]/g, "");
const okTranscript = flat.includes("endpointer") && (flat.includes("tyger") || flat.includes("tiger"));
const okAudio = bytes > 24000 * 2 * 0.5;
const pass = okKind && okTranscript && okAudio;
console.log(`checks: endpointer=${okKind} transcript=${okTranscript} audio=${okAudio}`);
console.log(pass ? "PASS" : "FAIL");
if (!pass) console.log("--- relay log tail ---\n" + log.split("\n").slice(-12).join("\n"));
writeFileSync(join(dir, "relay.log"), log);
process.exit(pass ? 0 : 1);
