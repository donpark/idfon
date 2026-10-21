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
  // the language knob (IDFON_VOICE_LANG, BCP-47); unset = provider auto-detect
  const lang = process.env.IDFON_VOICE_LANG;

  if ((cfg.provider || "openai-compatible") === "deepgram") {
    // Deepgram's listen API (the cascade preset's provider).
    const host = (cfg.base_url || "https://api.deepgram.com").replace(/\/$/, "");
    const params = new URLSearchParams({ model: cfg.stt_model || "nova-3", smart_format: "true" });
    if (lang) params.set("language", lang.split("-")[0]);
    const response = await fetch(`${host}/v1/listen?${params}`, {
      method: "POST",
      headers: {
        authorization: `Token ${apiKey({ ...cfg, api_key_env: cfg.api_key_env || "DEEPGRAM_API_KEY" })}`,
        "content-type": "audio/wav",
      },
      body: wavWrap(pcm),
    });
    if (!response.ok) throw new Error(`stt HTTP ${response.status}: ${await response.text()}`);
    return (await response.json()).results?.channels?.[0]?.alternatives?.[0]?.transcript ?? "";
  }

  const form = new FormData();
  form.append("file", new Blob([wavWrap(pcm)], { type: "audio/wav" }), "audio.wav");
  form.append("model", cfg.stt_model || "openai/whisper-1");
  if (lang) form.append("language", lang.split("-")[0]);
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
      local: wrap.local === true, // wrap = this instance's own agent: bridge routes locally
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
  const spoken = spokenText(text);
  if ((cfg.provider || "openai-compatible") === "elevenlabs") {
    return speakElevenLabs(cfg, spoken, peerId);
  }
  await play(peerId, await synthesize(spoken));
}

/// The spoken form of a reply: `IDFON-SPEAK/1` carries it in its `text` field
/// (docs/voice-multimodal.md); every other IDFON-*/1 envelope block is markup
/// that must never be read aloud (hearing it read is the 'countdown' gibberish).
function spokenText(reply) {
  const speak = /IDFON-SPEAK\/1\s*\n(\{[^\n]*\})/.exec(reply);
  if (speak) {
    try {
      const t = JSON.parse(speak[1]).text;
      if (t) return String(t).trim();
    } catch { /* fall through to stripping */ }
  }
  return reply.replace(/IDFON-[A-Z-]+\/1\s*\n\{[^\n]*\}/g, "").trim();
}

/// The caller's chat shows spoken turns as bubbles: each transcript rides a
/// plain message as an IDFON-CALL/1 envelope (Models.MessageKind.callTranscript).
/// `call_id`/`turn_id` are required by the app's decoder (it upserts streaming
/// snapshots per turn); `role` is "caller" | "agent". No capability ticket:
/// the holder attaches only grants whose issuer is the target — a ticketless
/// message rides the phone's signature + known-peer gate.
// shortcut: one call per relay process (the greet-once and frame counters are
// process-global) — mint a new call id when the relay learns call boundaries.
let callId = `call-${Date.now().toString(36)}`;
let turnSeq = 0;
async function sendTranscript(peerId, role, text, isFinal) {
  const turnId = `${callId}-t${turnSeq++}`;
  const body = JSON.stringify({ call_id: callId, turn_id: turnId, role, text, final: isFinal });
  await fetch(`${bridge}/send`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-idfon-channel-secret": secret },
    body: JSON.stringify({
      peer_id: peerId, endpoint_id: peerId, capability_ticket: null,
      text: `IDFON-CALL/1\n${body}`, await_reply: false,
    }),
  });
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
let frames = 0;
let greeted = false;
// Turn work runs off the frame loop, in order (see handleTurn).
let turnChain = Promise.resolve();

// The tyger chain is the authoritative endpointer (src/tyger/endpointer.ts);
// the energy path above stays as the fail-open fallback. IDFON_ENDPOINTER=energy opts out.
let tyger = null;

async function onFrame(frame) {
  const pcm = Buffer.from(frame.pcm_base64, "base64");
  frames += 1;
  if (frames === 1 || frames % 500 === 0) log.info("frames", { count: frames, peer_id: frame?.peer_id });
  // Greet on connect: the live server-cascade plan has no greet turn — the
  // engine's greeting IS the "answer" the caller hears. Without it the call
  // is silent until the caller speaks (the "no sound at all" report).
  if (frames === 1 && !greeted) {
    greeted = true;
    const greeting = process.env.IDFON_VOICE_GREETING || "Hello! I'm here whenever you're ready.";
    log.info("greet", { text: greeting });
    speak(greeting, frame?.peer_id).catch((error) => log.error("greet failed", { error: String(error) }));
    sendTranscript(frame?.peer_id, "agent", greeting, true).catch((error) => log.warn("transcript send failed", { error: String(error) }));
  }
  utterance = Buffer.concat([utterance, pcm]);
  const decisions = tyger ? await tyger.push(pcm) : [];
  const tygerEnd = decisions.includes("endpoint");
  if (decisions.includes("backchannel") || decisions.includes("barge")) {
    log.info("tyger", { decisions: decisions.join(",") });
  }
  if (isLoud(pcm)) {
    if (!speaking) { speaking = true; utterance = pcm; }
    quiet = 0;
    if (!tygerEnd) return;
  }
  if (!speaking && !tygerEnd) { utterance = Buffer.alloc(0); return; }
  quiet += pcm.length / 2;
  if (quiet < QUIET_FRAMES && !tygerEnd) return;
  speaking = false;
  quiet = 0;
  const speech = utterance;
  utterance = Buffer.alloc(0);
  if (speech.length < RATE) return; // ignore blips
  // Turn processing must not block frame intake: while STT + the agent + TTS
  // run, caller audio keeps arriving and the endpointer must see it in real
  // time. (Awaiting here compounded seconds of lag per turn — 500 frames of
  // ~10 s audio took 14-20 s wall.) Turns stay in order on a chain.
  const peerId = frame?.peer_id;
  const trace = frame?.trace;
  turnChain = turnChain.then(() => handleTurn(speech, peerId, trace));
}

async function handleTurn(speech, peerId, trace) {
  const started = Date.now();
  try {
    const transcript = (await transcribe(speech)).trim();
    if (!transcript) return;
    const sttMs = Date.now() - started;
    log.info("heard", {
      transcript,
      stt_ms: sttMs,
      capture_ms: Math.round((speech.length / 2 / RATE) * 1000),
    });
    sendTranscript(peerId, "caller", transcript, true).catch((error) => log.warn("transcript send failed", { error: String(error) }));
    const replyStart = Date.now();
    const reply = (await forward(transcript)).trim();
    if (!reply) return;
    const replyMs = Date.now() - replyStart;
    log.info("reply", { reply, peer_id: peerId, trace, reply_ms: replyMs });
    sendTranscript(peerId, "agent", spokenText(reply), true).catch((error) => log.warn("transcript send failed", { error: String(error) }));
    await speak(reply, peerId);
    log.info("turn timing", { stt_ms: sttMs, reply_ms: replyMs, total_ms: Date.now() - started });
  } catch (error) {
    log.error("turn failed", { peer_id: peerId, trace, error: String(error) });
  }
}

async function main() {
  if (process.env.IDFON_ENDPOINTER !== "energy") {
    try {
      const { createTygerEndpointer } = await import("./src/tyger/endpointer.ts");
      tyger = await createTygerEndpointer();
      log.info("endpointer", { kind: "tyger" });
    } catch (error) {
      log.warn("endpointer", { kind: "energy", reason: String(error) });
    }
  } else {
    log.info("endpointer", { kind: "energy" });
  }
  log.info("listening", { bridge });
  // Declare the real pipeline: the holder's startup info lists the client's
  // on-device options; the info screen should show what this engine uses.
  fetch(`${bridge}/voice/info`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-idfon-channel-secret": secret },
    body: JSON.stringify({
      engine: { stt: engine.stt?.provider ?? "?", tts: engine.tts?.provider ?? "?" },
      options: [
        { id: `server:${engine.stt?.provider ?? "?"}`, kind: "stt", label: `Deepgram ${engine.stt?.stt_model || "nova-3"}`, side: "server" },
        { id: `server:${engine.tts?.provider ?? "?"}`, kind: "tts", label: engine.tts?.provider === "elevenlabs" ? "ElevenLabs" : "TTS", side: "server" },
      ],
    }),
  }).catch((error) => log.warn("voice info post failed", { error: String(error) }));
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
