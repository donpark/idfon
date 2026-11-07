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

import { CallRecorder } from "./src/observe/collector.ts";
import { appendCallRecord, callRecordPath } from "./src/observe/emitter.ts";

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
      peer_id: wrap.peer_id, endpoint_id: wrap.endpoint_id,
      // A local wrap posts straight to this instance's agent: no holder ticket
      // is involved, and the bridge rejects a ticket it cannot use.
      ...(wrap.local === true ? {} : { capability_ticket: wrap.ticket }),
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

/// A hard start or end of any generated utterance clicks. Fade the edge in
/// place (10 ms); the whole-cue path fades both, the streamed path fades the
/// first and last chunks.
function fadeInEdge(pcm, ms = 10) {
  const samples = Math.min(Math.floor(pcm.length / 2), Math.round((ms / 1000) * RATE));
  for (let i = 0; i < samples; i += 1) {
    pcm.writeInt16LE(Math.round(pcm.readInt16LE(i * 2) * (i / samples)), i * 2);
  }
}

function fadeOutEdge(pcm, ms = 10) {
  const samples = Math.min(Math.floor(pcm.length / 2), Math.round((ms / 1000) * RATE));
  for (let i = 0; i < samples; i += 1) {
    const tail = pcm.length - 2 * (i + 1);
    pcm.writeInt16LE(Math.round(pcm.readInt16LE(tail) * (i / samples)), tail);
  }
}

function fadeEdges(pcm, ms = 10) {
  fadeInEdge(pcm, ms);
  fadeOutEdge(pcm, ms);
}

const TARGET_RMS = 0.12; // ~-18.4 dBFS; same target for cues and replies
const PREFIX_MS = 200;    // reply level estimate window

function gainFor(pcm) {
  const n = Math.floor(pcm.length / 2);
  if (!n) return 1;
  let sum = 0;
  let peak = 0;
  for (let i = 0; i < n; i += 1) {
    const sample = pcm.readInt16LE(i * 2) / 32768;
    sum += sample * sample;
    const magnitude = Math.abs(sample);
    if (magnitude > peak) peak = magnitude;
  }
  const rms = Math.sqrt(sum / n);
  if (!rms) return 1;
  let gain = TARGET_RMS / rms;
  if (peak * gain > 0.95) gain = 0.95 / peak;
  return Math.min(Math.max(gain, 0.25), 3);
}

function applyGain(pcm, gain) {
  if (!gain || gain === 1) return;
  for (let i = 0; i < pcm.length; i += 2) {
    const scaled = Math.round(pcm.readInt16LE(i) * gain);
    pcm.writeInt16LE(Math.max(-32768, Math.min(32767, scaled)), i);
  }
}

function normalizePcm(pcm) {
  applyGain(pcm, gainFor(pcm));
}

async function elevenLabsStream(cfg, text, signal) {
  const base = (cfg.base_url || "https://api.elevenlabs.io/v1").replace(/\/$/, "");
  const url = `${base}/text-to-speech/${cfg.voice}?output_format=pcm_${RATE}`;
  const response = await fetch(url, {
    method: "POST",
    headers: { "xi-api-key": apiKey(cfg), "content-type": "application/json" },
    body: JSON.stringify({
      text,
      model_id: cfg.model || "eleven_turbo_v2_5",
      voice_settings: cfg.voice_settings ?? {
        stability: 0.5,
        similarity_boost: 0.75,
        style: 0,
        use_speaker_boost: true,
      },
    }),
    signal,
  });
  if (!response.ok || !response.body) throw new Error(`tts HTTP ${response.status}: ${await response.text()}`);
  return response.body.getReader();
}

async function elevenLabsPcm(cfg, text, signal) {
  const reader = await elevenLabsStream(cfg, text, signal);
  const parts = [];
  let carry = Buffer.alloc(0);
  for (;;) {
    if (signal?.aborted) return null;
    const { value, done } = await reader.read();
    if (done) break;
    carry = Buffer.concat([carry, Buffer.from(value)]);
    const usable = carry.length - (carry.length % 2);
    if (usable > 0) {
      parts.push(Buffer.from(carry.subarray(0, usable)));
      carry = carry.subarray(usable);
    }
  }
  return parts.length ? Buffer.concat(parts) : null;
}

/// A short cue (greeting/filler/backchannel) is synthesized whole, normalized
/// and edge-faded once; the result is cached for this voice/model.
async function cuePcm(cfg, text, signal) {
  const pcm = await elevenLabsPcm(cfg, text, signal);
  if (!pcm) return null;
  normalizePcm(pcm);
  fadeEdges(pcm);
  return pcm;
}

/// The long reply streams: pace chunks for barge cancellability, estimate the
/// level from the first 200 ms and apply it to the whole utterance, fade the
/// first and last chunk.
async function speakElevenLabs(cfg, text, peerId, signal) {
  const reader = await elevenLabsStream(cfg, text, signal);
  let carry = Buffer.alloc(0);
  let clock = 0;
  let audioMs = 0;
  let pending = null;
  let first = true;
  let gain = null;
  const pre = [];
  let preMs = 0;
  const durationOf = (chunk) => (chunk.length / 2 / RATE) * 1000;
  const post = async (chunk, final = false) => {
    if (!chunk || signal.aborted) return;
    applyGain(chunk, gain ?? 1);
    if (first) { fadeInEdge(chunk); first = false; }
    if (final) fadeOutEdge(chunk);
    if (!clock) clock = Date.now();
    const due = clock + audioMs;
    audioMs += durationOf(chunk);
    const wait = due - Date.now();
    if (wait > 1) await new Promise((resolve) => setTimeout(resolve, wait));
    if (signal.aborted) return;
    await play(peerId, chunk);
  };
  const flushPre = async (final = false) => {
    if (gain === null) {
      const all = Buffer.concat(pre);
      gain = all.length ? gainFor(all) : 1;
    }
    if (final) {
      for (let i = 0; i < pre.length; i += 1) {
        await post(pre[i], i === pre.length - 1);
      }
      pre.length = 0;
      pending = null;
      return;
    }
    const last = pre.pop();
    for (const chunk of pre) await post(chunk);
    pending = last ?? null;
    pre.length = 0;
  };
  for (;;) {
    if (signal.aborted) return;
    const { value, done } = await reader.read();
    if (done) break;
    carry = Buffer.concat([carry, Buffer.from(value)]);
    const usable = carry.length - (carry.length % 2);
    if (usable > 0) {
      const chunk = Buffer.from(carry.subarray(0, usable));
      carry = carry.subarray(usable);
      if (gain === null) {
        pre.push(chunk);
        preMs += durationOf(chunk);
        if (preMs >= PREFIX_MS) await flushPre();
      } else {
        if (pending) await post(pending);
        pending = chunk;
      }
    }
  }
  if (gain === null) await flushPre(true);
  else if (pending) await post(pending, true);
}

/** Speak text on the call, streaming when the TTS provider supports it.
 * Serialized and generation-stamped: a barge invalidates queued speech. */
function speak(text, peerId, kind = "reply") {
  const generation = speechGeneration;
  const run = speechChain.then(async () => {
    if (generation !== speechGeneration) return;
    await doSpeak(text, peerId, kind);
  });
  speechChain = run.catch(() => {});
  return run;
}

async function doSpeak(text, peerId, kind) {
  const controller = new AbortController();
  botAbort = controller;
  botSpeech.speaking = true;
  botSpeech.kind = kind;
  botSpeech.onsetMs = Date.now() - callStartedAt;
  bargePending = false;
  try {
    const cfg = engine.tts || {};
    const spoken = spokenText(text);
    if ((cfg.provider || "openai-compatible") === "elevenlabs") {
      if (isCue(kind)) {
        let pcm = cueCache.get(text);
        if (!pcm) {
          pcm = await cuePcm(cfg, spoken, controller.signal);
          if (pcm) cueCache.set(text, pcm);
        }
        if (pcm && !controller.signal.aborted) await play(peerId, pcm);
      } else {
        await speakElevenLabs(cfg, spoken, peerId, controller.signal);
      }
    } else if (!controller.signal.aborted) {
      const pcm = await synthesize(spoken);
      normalizePcm(pcm);
      fadeEdges(pcm);
      await play(peerId, pcm);
    }
  } catch (error) {
    if (error?.name !== "AbortError") throw error;
  } finally {
    botSpeech.speaking = false;
    botSpeech.kind = null;
    botSpeech.stopMs = Date.now() - callStartedAt;
    if (botAbort === controller) botAbort = null;
  }
}

/** A floor take while the agent speaks: stop the TTS, drop the turn's reply
 * and any queued filler/backchannel. The already-posted tail (a few hundred
 * ms) plays out; no more PCM is posted. */
function stopSpeaking(reason) {
  // A barge during a filler/backchannel/greeting stops only that cue; only a
  // barge on the reply cancels the turn. (The filler is not the answer.)
  const cancelsTurn = botSpeech.speaking && botSpeech.kind === "reply";
  speechGeneration += 1;
  if (cancelsTurn) turnGeneration += 1;
  botAbort?.abort();
  if (botSpeech.speaking) log.info("barge", { reason, kind: botSpeech.kind });
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
// Per-call observation record (src/observe/): turns and truncation marks feed a
// CallRecorder, one JSONL line at teardown. Fully passive.
const callStartedAt = Date.now();
const recorder = new CallRecorder(callId, new Date());
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
let bargePending = false; // a floor take must last BARGE_MIN_MS before it cancels a reply
let quiet = 0;
let utterance = Buffer.alloc(0);
let frames = 0;
let greeted = false;
// Turn work runs off the frame loop, in order (see handleTurn).
let turnChain = Promise.resolve();

// The tyger chain is the authoritative endpointer (src/tyger/endpointer.ts);
// the energy path above stays as the fail-open fallback. IDFON_ENDPOINTER=energy opts out.
let tyger = null;
// Shadow backchannel detector (src/bcd/): model events land in the call
// record only, never in behavior. IDFON_BCD=off disables, =on requires the
// bundle; default 'auto' loads it when present (fail-open).
let bcd = null;
// bcd bot_state (src/bcd/engine.ts botStateRow): the bot's speech clock.
// shortcut: each speak() is one utterance and the gap before it (the agent's
// round trip) is always >= 200 ms, so the "last >=200 ms pause" clock restarts
// at onset; pauses inside a streamed TTS run are invisible here.
const botSpeech = { speaking: false, kind: null, onsetMs: null, stopMs: null };
let botAbort = null;
let speechChain = Promise.resolve();
let speechGeneration = 0;
let turnGeneration = 0;
let currentPeerId = null;
const BC_POOL = ["Yeah.", "Right.", "Got it.", "I see."];
const GREETING_TEXT = process.env.IDFON_VOICE_GREETING || "Hello! I'm here whenever you're ready.";
const FILLER_TEXTS = (process.env.IDFON_VOICE_FILLERS ?? "One moment.|Still checking.")
  .split("|").map((s) => s.trim()).filter(Boolean);
const cueCache = new Map();
function isCue(kind) {
  return kind === "greeting" || kind === "backchannel" || kind === "filler";
}
async function primeCues() {
  const cfg = engine.tts || {};
  if ((cfg.provider || "openai-compatible") !== "elevenlabs") return;
  const texts = [...new Set([GREETING_TEXT, ...FILLER_TEXTS, ...BC_POOL])];
  for (const text of texts) {
    if (cueCache.has(text)) continue;
    try {
      const pcm = await cuePcm(cfg, spokenText(text));
      if (pcm) cueCache.set(text, pcm);
    } catch (error) {
      log.warn("cue cache failed", { text, error: String(error) });
    }
  }
  log.info("cues cached", { count: cueCache.size });
}
let bcIndex = 0;
let lastBcAt = 0;

/** A short reaction while the caller still holds the floor (BCD decision). */
function speakBackchannel() {
  const now = Date.now();
  if (now - lastBcAt < 1500 || botSpeech.speaking || speaking || !currentPeerId) return;
  lastBcAt = now;
  const text = BC_POOL[bcIndex++ % BC_POOL.length];
  log.info("backchannel", { text });
  speak(text, currentPeerId, "backchannel").catch((error) => log.warn("backchannel failed", { error: String(error) }));
}

async function onFrame(frame) {
  const pcm = Buffer.from(frame.pcm_base64, "base64");
  currentPeerId = frame?.peer_id ?? currentPeerId;
  frames += 1;
  if (frames === 1 || frames % 500 === 0) log.info("frames", { count: frames, peer_id: frame?.peer_id });
  // Greet on connect: the live server-cascade plan has no greet turn — the
  // engine's greeting IS the "answer" the caller hears. Without it the call
  // is silent until the caller speaks (the "no sound at all" report).
  if (frames === 1 && !greeted) {
    greeted = true;
    const greeting = GREETING_TEXT;
    log.info("greet", { text: greeting });
    const greetStart = Date.now() - callStartedAt;
    speak(greeting, frame?.peer_id, "greeting")
      .then(() => recorder.addTurn({ text: greeting, role: "agent", started_ms: greetStart, duration_ms: Date.now() - callStartedAt - greetStart }))
      .catch((error) => log.error("greet failed", { error: String(error) }));
    sendTranscript(frame?.peer_id, "agent", greeting, true).catch((error) => log.warn("transcript send failed", { error: String(error) }));
  }
  utterance = Buffer.concat([utterance, pcm]);
  const decisions = tyger ? await tyger.push(pcm) : [];
  const tygerEnd = decisions.includes("endpoint");
  if (decisions.includes("backchannel") || decisions.includes("barge")) {
    log.info("tyger", { decisions: decisions.join(",") });
  }
  if (decisions.includes("barge")) {
    recorder.recordPlaybackTruncated(Date.now() - callStartedAt);
    stopSpeaking("tyger barge");
  }
  if (bcd) bcd.push(pcm);
  if (isLoud(pcm)) {
    if (!speaking) { speaking = true; utterance = pcm; }
    quiet = 0;
    if (bargePending && (!botSpeech.speaking || botSpeech.kind !== "reply" || !speaking)) {
      bargePending = false; // the reply ended or the acknowledgement stopped
    } else if (bargePending && utterance.length / 2 / RATE >= 0.4) {
      bargePending = false;
      stopSpeaking("bcd floor_take");
    }
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
  const turnEndMs = Date.now() - callStartedAt;
  turnChain = turnChain.then(() => handleTurn(speech, peerId, trace, turnEndMs));
}

async function handleTurn(speech, peerId, trace, turnEndMs) {
  const started = Date.now();
  const generation = turnGeneration;
  try {
    const transcript = (await transcribe(speech)).trim();
    if (!transcript) return;
    const sttMs = Date.now() - started;
    const captureMs = Math.round((speech.length / 2 / RATE) * 1000);
    log.info("heard", {
      transcript,
      stt_ms: sttMs,
      capture_ms: captureMs,
    });
    // Observation record: the user turn is the captured utterance, timed from
    // its audio ([endpoint - capture, endpoint], call-relative).
    recorder.addTurn({ text: transcript, role: "user", started_ms: turnEndMs - captureMs, duration_ms: captureMs });
    sendTranscript(peerId, "caller", transcript, true).catch((error) => log.warn("transcript send failed", { error: String(error) }));
    const replyStart = Date.now();
    // Cover a slow agent/tool turn without talking over the reply: a filler
    // after ~1.2 s and a second at ~6 s, chained so they never overlap, and
    // awaited before the real reply. Disable with IDFON_VOICE_FILLERS="".
    const fillers = FILLER_TEXTS;
    let replied = false;
    let fillerChain = Promise.resolve();
    const fillerTimers = [1200, 6000].map((ms, i) => setTimeout(() => {
      const text = fillers[i];
      if (replied || !text) return;
      fillerChain = fillerChain.then(async () => {
        if (replied || generation !== turnGeneration) return;
        log.info("filler", { text, after_ms: ms });
        await speak(text, peerId, "filler");
      }).catch((error) => log.warn("filler failed", { error: String(error) }));
    }, ms));
    let reply;
    try {
      reply = (await forward(transcript)).trim();
    } finally {
      replied = true;
      for (const timer of fillerTimers) clearTimeout(timer);
    }
    const replyMs = Date.now() - replyStart; // the agent turn, not the filler
    await fillerChain; // the reply must not start inside a filler
    if (generation !== turnGeneration) {
      log.info("turn dropped after barge", { peer_id: peerId });
      return;
    }
    if (!reply) return;
    log.info("reply", { reply, peer_id: peerId, trace, reply_ms: replyMs });
    sendTranscript(peerId, "agent", spokenText(reply), true).catch((error) => log.warn("transcript send failed", { error: String(error) }));
    const playStart = Date.now();
    await speak(reply, peerId, "reply");
    // Observation record: the agent turn is the delivery window (TTS + posting),
    // approximating when the caller hears the agent.
    recorder.addTurn({ text: spokenText(reply), role: "agent", started_ms: playStart - callStartedAt, duration_ms: Date.now() - playStart });
    log.info("turn timing", { stt_ms: sttMs, reply_ms: replyMs, total_ms: Date.now() - started });
  } catch (error) {
    log.error("turn failed", { peer_id: peerId, trace, error: String(error) });
  }
}

// One observation record per call at teardown (src/observe/). Passive: a sink
// failure is logged and dropped. shortcut: a process crash loses the call's
// record — move to incremental flushes if records go missing in practice.
let recordEmitted = false;
async function emitCallRecord() {
  if (recordEmitted) return;
  recordEmitted = true;
  try {
    if (bcd) await bcd.flush();
    const path = callRecordPath();
    if (path) {
      const record = recorder.build();
      appendCallRecord(path, record);
      log.info("call record", { path, call_id: record.call_id, turn_count: record.turn_count });
    }
  } catch (error) {
    log.warn("call record failed", { error: String(error) });
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
  if (process.env.IDFON_BCD !== "off") {
    try {
      const { createRequire } = await import("node:module");
      const ort = createRequire(import.meta.url)("onnxruntime-node");
      const { loadBundle } = await import("./src/bcd/bundle.ts");
      const { BcdEngine, botStateRow, CHUNK_N } = await import("./src/bcd/engine.ts");
      const { BcdDecisions } = await import("./src/bcd/decisions.ts");
      const { makeResampler, pcm16ToFloat } = await import("./src/tyger/stream.ts");
      const bundle = loadBundle();
      const model = new BcdEngine(await ort.InferenceSession.create(bundle.modelPath));
      const decider = new BcdDecisions();
      const resample = makeResampler();
      let pending = [];
      let pump = Promise.resolve(); // serializes the stateful engine
      bcd = {
        push(pcm) {
          pending.push(...resample(pcm16ToFloat(new Uint8Array(pcm))));
          pump = pump.then(async () => {
            while (pending.length >= CHUNK_N) {
              const chunk = pending.slice(0, CHUNK_N);
              pending = pending.slice(CHUNK_N);
              const now = Date.now() - callStartedAt;
              const sinceOnset = botSpeech.onsetMs === null ? 5 : (now - botSpeech.onsetMs) / 1000;
              const sinceStop = botSpeech.stopMs === null ? 5 : (now - botSpeech.stopMs) / 1000;
              const row = botStateRow(
                botSpeech.speaking, sinceOnset, sinceOnset, sinceStop,
                botSpeech.kind === "filler");
              for (const f of await model.chunk(chunk, [...row, ...row])) {
                const d = decider.onFrame(f.intent, f.vad);
                if (d.kind !== "none") {
                  recorder.recordBcdEvent(d.kind, now, d.p);
                  log.info("bcd", { kind: d.kind, p: d.p });
                  if (d.kind === "floor_take" && botSpeech.speaking) {
                    // A brief "yeah" is an acknowledgement, not a floor take;
                    // let the reply finish unless the caller keeps talking.
                    if (botSpeech.kind === "reply") bargePending = true;
                    else stopSpeaking("bcd floor_take");
                  } else if (d.kind === "backchannel" && !botSpeech.speaking) {
                    speakBackchannel();
                  }
                }
              }
            }
          }).catch((error) => log.warn("bcd", { error: String(error) }));
        },
        reset() {
          decider.reset();
        },
        flush() {
          return pump;
        },
      };
      recorder.markBcdActive();
      log.info("bcd", { kind: "shadow", model: bundle.modelPath });
    } catch (error) {
      log[process.env.IDFON_BCD === "on" ? "warn" : "info"]("bcd off", { reason: String(error) });
    }
  }
  log.info("listening", { bridge });
  void primeCues();
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
  await turnChain; // in-flight turns still land in the record
  await emitCallRecord();
}

main().catch(async (error) => { log.error("fatal", { error: String(error) }); await emitCallRecord(); process.exit(1); });

// A supervised restart (or Ctrl-C) must not lose the call record: flush it
// before exiting. SIGKILL still loses it, by design.
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    emitCallRecord().finally(() => process.exit(0));
  });
}
