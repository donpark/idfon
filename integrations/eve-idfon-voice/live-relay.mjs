#!/usr/bin/env node
// Standalone voice relay for idfon live calls: caller audio -> STT -> wrapped
// agent -> TTS -> caller. It is a plain Node process, not an Eve agent, so it
// can hold a long-lived call session.
//
//   IDFON_VOICE_ENGINE='{"stt":{...},"tts":{...},"wrap":{...}}' \
//     node live-relay.mjs
//
// Engine blocks are OpenAI-compatible here (see eve-idfon-voice providers for
// the full seam). `wrap` names the agent to relay to; without it the relay
// echoes the transcript (a connectivity check).

const bridge = process.env.IDFON_BRIDGE_URL || "http://127.0.0.1:18766";
const secret = process.env.IDFON_BRIDGE_SECRET || "m2-test-secret";
const engine = process.env.IDFON_VOICE_ENGINE ? JSON.parse(process.env.IDFON_VOICE_ENGINE) : {};
const RATE = 24_000;

// Inline structured logger: this script is standalone (its own package) and must
// not reach into eve-idfon internals. Single-line JSON on stderr, tagged
// `idfon.live-relay`, mirroring log.mjs.
const log = ((service) => {
  const emit = (level, message, fields) => {
    const record = { ts: new Date().toISOString(), level, service, target: "idfon.live-relay", message };
    if (fields) for (const [k, v] of Object.entries(fields)) if (v != null && v !== "") record[k] = v;
    process.stderr.write(JSON.stringify(record) + "\n");
  };
  return { info: (m, f) => emit("info", m, f), warn: (m, f) => emit("warn", m, f), error: (m, f) => emit("error", m, f) };
})(process.env.IDFON_SERVICE_NAME ?? "eve-idfon-voice");

function apiKey(cfg) {
  const name = cfg?.api_key_env || "AI_GATEWAY_API_KEY";
  const key = process.env[name] || "";
  if (!key && !cfg?.allow_missing_key) throw new Error(`${name} is not set`);
  return key;
}

function wavWrap(pcm) {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0); header.writeUInt32LE(36 + pcm.length, 4); header.write("WAVE", 8);
  header.write("fmt ", 12); header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22); header.writeUInt32LE(RATE, 24); header.writeUInt32LE(RATE * 2, 28);
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34); header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

async function transcribe(pcm) {
  const cfg = engine.stt || {};
  const base = (cfg.base_url || "https://ai-gateway.vercel.sh/v1").replace(/\/$/, "");
  const form = new FormData();
  form.append("file", new Blob([wavWrap(pcm)], { type: "audio/wav" }), "audio.wav");
  form.append("model", cfg.stt_model || "openai/whisper-1");
  const key = apiKey(cfg);
  const response = await fetch(`${base}/audio/transcriptions`, {
    method: "POST", headers: key ? { authorization: `Bearer ${key}` } : {}, body: form,
  });
  if (!response.ok) throw new Error(`stt HTTP ${response.status}: ${await response.text()}`);
  return (await response.json()).text ?? "";
}

async function synthesize(text) {
  const cfg = engine.tts || {};
  const base = (cfg.base_url || "https://ai-gateway.vercel.sh/v1").replace(/\/$/, "");
  const key = apiKey(cfg);
  const response = await fetch(`${base}/audio/speech`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(key ? { authorization: `Bearer ${key}` } : {}) },
    body: JSON.stringify({
      model: cfg.tts_model || "openai/tts-1", input: text,
      voice: cfg.voice || "alloy", response_format: "pcm",
    }),
  });
  if (!response.ok) throw new Error(`tts HTTP ${response.status}: ${await response.text()}`);
  return Buffer.from(await response.arrayBuffer());
}

async function forward(text) {
  const wrap = engine.wrap;
  if (!wrap) return text; // no wrapped agent: echo the transcript back (check)
  const replyTo = `wrap-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const response = await fetch(`${bridge}/send`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-idfon-channel-secret": secret },
    body: JSON.stringify({
      peer_id: wrap.peer_id, endpoint_id: wrap.endpoint_id, capability_ticket: wrap.ticket,
      text, a2a_depth: 1, await_reply: true, reply_to: replyTo, reply_timeout_ms: 60_000,
    }),
  });
  if (!response.ok) throw new Error(`send HTTP ${response.status}`);
  return ((await response.json()).reply?.text ?? "").trim();
}

async function play(peerId, pcm) {
  const response = await fetch(`${bridge}/live/audio`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-idfon-channel-secret": secret },
    body: JSON.stringify({ peer_id: peerId, pcm_base64: pcm.toString("base64") }),
  });
  if (!response.ok) throw new Error(`live audio HTTP ${response.status}`);
}

/** ElevenLabs chunked TTS: post each PCM chunk as it arrives. */
async function speakElevenLabs(cfg, text, peerId) {
  const base = (cfg.base_url || "https://api.elevenlabs.io/v1").replace(/\/$/, "");
  const url = `${base}/text-to-speech/${cfg.voice}?output_format=pcm_${RATE}`;
  const response = await fetch(url, {
    method: "POST",
    headers: { "xi-api-key": apiKey(cfg), "content-type": "application/json" },
    body: JSON.stringify({ text, model_id: cfg.model || "eleven_turbo_v2_5" }),
  });
  if (!response.ok || !response.body) throw new Error(`tts HTTP ${response.status}: ${await response.text()}`);
  const reader = response.body.getReader();
  let carry = Buffer.alloc(0);
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    carry = Buffer.concat([carry, Buffer.from(value)]);
    const usable = carry.length - (carry.length % 2);
    if (usable > 0) {
      await play(peerId, carry.subarray(0, usable));
      carry = carry.subarray(usable);
    }
  }
}

/** Speak text on the call, streaming when the TTS provider supports it. */
async function speak(text, peerId) {
  const cfg = engine.tts || {};
  if ((cfg.provider || "openai-compatible") === "elevenlabs") {
    return speakElevenLabs(cfg, text, peerId);
  }
  await play(peerId, await synthesize(text));
}

// Energy endpointer (|s16| > 300, 800 ms quiet tail), mirroring idfon-voice.
const THRESHOLD = 300;
const QUIET_FRAMES = (RATE * 0.8);
function isLoud(pcm) {
  for (let i = 0; i + 1 < pcm.length; i += 2) {
    const sample = pcm.readInt16LE(i);
    if (sample > THRESHOLD || sample < -THRESHOLD) return true;
  }
  return false;
}

let speaking = false;
let quiet = 0;
let utterance = Buffer.alloc(0);

async function onFrame(frame) {
  const pcm = Buffer.from(frame.pcm_base64, "base64");
  utterance = Buffer.concat([utterance, pcm]);
  if (isLoud(pcm)) {
    if (!speaking) { speaking = true; utterance = pcm; }
    quiet = 0;
    return;
  }
  if (!speaking) { utterance = Buffer.alloc(0); return; }
  quiet += pcm.length / 2;
  if (quiet < QUIET_FRAMES) return;
  speaking = false;
  quiet = 0;
  const speech = utterance;
  utterance = Buffer.alloc(0);
  if (speech.length < RATE) return; // ignore blips
  try {
    const transcript = (await transcribe(speech)).trim();
    if (!transcript) return;
    log.info("heard", { transcript });
    const reply = (await forward(transcript)).trim();
    if (!reply) return;
    log.info("reply", { reply, peer_id: frame?.peer_id, trace: frame?.trace });
    await speak(reply, frame.peer_id);
  } catch (error) {
    log.error("turn failed", { peer_id: frame?.peer_id, trace: frame?.trace, error: String(error) });
  }
}

async function main() {
  log.info("listening", { bridge });
  const response = await fetch(`${bridge}/live/stream`, { headers: { accept: "text/event-stream" } });
  if (!response.ok || !response.body) throw new Error(`stream HTTP ${response.status}`);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let index;
    while ((index = buffer.indexOf("\n\n")) >= 0) {
      const event = buffer.slice(0, index);
      buffer = buffer.slice(index + 2);
      const line = event.split("\n").find((l) => l.startsWith("data: "));
      if (!line) continue;
      let frame;
      try { frame = JSON.parse(line.slice(6)); } catch { continue; }
      if (frame.type === "audio.frame") await onFrame(frame);
    }
  }
}

main().catch((error) => { log.error("fatal", { error: String(error) }); process.exit(1); });
