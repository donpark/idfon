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
  if (!wrap) return { text, agent_ms: null }; // no wrapped agent: echo the transcript back (check)
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
  const reply = (await response.json()).reply ?? {};
  // `agent_ms` is the bridge's own clock for the agent's generation; the
  // caller's `reply_ms` also carries the bridge round trip on top of it.
  return { text: (reply.text ?? "").trim(), agent_ms: reply.agent_ms ?? null };
}

async function play(peerId, pcm, lat) {
  const t0 = Date.now();
  // The first PCM posted to the bridge is the earliest the caller can hear
  // the reply — the ledger's "heard" clock starts here.
  if (lat && lat.tts_first_audio_ms === null) lat.tts_first_audio_ms = t0 - callStartedAt;
  const response = await fetch(`${bridge}/live/audio`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-idfon-channel-secret": secret },
    body: JSON.stringify({ peer_id: peerId, pcm_base64: pcm.toString("base64") }),
  });
  if (lat) lat.play_ms += Date.now() - t0;
  if (!response.ok) throw new Error(`live audio HTTP ${response.status}`);
}

/** ElevenLabs chunked TTS: post each PCM chunk as it arrives. */
async function speakElevenLabs(cfg, text, peerId, lat) {
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
      await play(peerId, carry.subarray(0, usable), lat);
      carry = carry.subarray(usable);
    }
  }
}

/** Speak text on the call, streaming when the TTS provider supports it. */
async function speak(text, peerId, lat) {
  botSpeech.speaking = true;
  botSpeech.onsetMs = Date.now() - callStartedAt;
  if (lat) lat.tts_start_ms = botSpeech.onsetMs;
  try {
    const cfg = engine.tts || {};
    const spoken = spokenText(text);
    if ((cfg.provider || "openai-compatible") === "elevenlabs") {
      return await speakElevenLabs(cfg, spoken, peerId, lat);
    }
    await play(peerId, await synthesize(spoken), lat);
  } finally {
    botSpeech.speaking = false;
    botSpeech.stopMs = Date.now() - callStartedAt;
  }
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
let quiet = 0;
let utterance = Buffer.alloc(0);
let frames = 0;
// The last frame whose audio was loud: the caller's utterance end, not the
// quiet-tail end. The gap to the endpoint decision is the endpointer's delay.
let lastVoicedMs = 0;
// Frame-loop cost: the model's own time. A push slower than the frame's audio
// duration means the loop is falling behind real time.
const pipeline = { pushTotal: 0 };
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
const botSpeech = { speaking: false, onsetMs: null, stopMs: null };

async function onFrame(frame) {
  const nowMs = Date.now() - callStartedAt;
  const pcm = Buffer.from(frame.pcm_base64, "base64");
  const loud = isLoud(pcm);
  if (loud) lastVoicedMs = nowMs;
  frames += 1;
  if (frames === 1 || frames % 500 === 0) log.info("frames", { count: frames, peer_id: frame?.peer_id });
  // Greet on connect: the live server-cascade plan has no greet turn — the
  // engine's greeting IS the "answer" the caller hears. Without it the call
  // is silent until the caller speaks (the "no sound at all" report).
  if (frames === 1 && !greeted) {
    greeted = true;
    const greeting = process.env.IDFON_VOICE_GREETING || "Hello! I'm here whenever you're ready.";
    log.info("greet", { text: greeting });
    const greetStart = Date.now() - callStartedAt;
    speak(greeting, frame?.peer_id)
      .then(() => recorder.addTurn({ text: greeting, role: "agent", started_ms: greetStart, duration_ms: Date.now() - callStartedAt - greetStart }))
      .catch((error) => log.error("greet failed", { error: String(error) }));
    sendTranscript(frame?.peer_id, "agent", greeting, true).catch((error) => log.warn("transcript send failed", { error: String(error) }));
  }
  utterance = Buffer.concat([utterance, pcm]);
  const pushStart = Date.now();
  const decisions = tyger ? await tyger.push(pcm) : [];
  const pushMs = Date.now() - pushStart;
  pipeline.pushTotal += pushMs;
  recorder.recordFramePush(pushMs);
  const tygerEnd = decisions.includes("endpoint");
  if (decisions.includes("backchannel") || decisions.includes("barge")) {
    log.info("tyger", { decisions: decisions.join(",") });
  }
  if (decisions.includes("barge")) recorder.recordPlaybackTruncated(Date.now() - callStartedAt);
  if (bcd) bcd.push(pcm);
  if (loud) {
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
  const turnEndMs = Date.now() - callStartedAt;
  const frameMs = frames > 0 ? Math.round(pipeline.pushTotal / frames) : 0;
  turnChain = turnChain.then(() => handleTurn(speech, peerId, trace, turnEndMs, {
    callerStopMs: lastVoicedMs,
    endpointSource: tygerEnd ? "tyger" : "energy",
    frameMs,
  }));
}

async function handleTurn(speech, peerId, trace, turnEndMs, turnInfo = {}) {
  const started = Date.now();
  const frameStart = pipeline.pushTotal;
  const frameCountStart = frames;
  try {
    const sttStart = Date.now();
    const transcript = (await transcribe(speech)).trim();
    if (!transcript) return;
    const sttMs = Date.now() - sttStart;
    const captureMs = Math.round((speech.length / 2 / RATE) * 1000);
    log.info("heard", {
      transcript,
      stt_ms: sttMs,
      capture_ms: captureMs,
    });
    // Observation record: the user turn is the captured utterance, timed from
    // its audio ([endpoint - capture, endpoint], call-relative).
    const turnIndex = recorder.addTurn({ text: transcript, role: "user", started_ms: turnEndMs - captureMs, duration_ms: captureMs });
    const callerStopMs = turnInfo.callerStopMs ?? turnEndMs;
    // The delay ledger: where the turn's waiting time goes. Every field is
    // call-relative ms; the gaps are what the caller feels.
    const lat = {
      turn_index: turnIndex,
      caller_stop_ms: callerStopMs,
      endpoint_ms: turnEndMs,
      endpoint_source: turnInfo.endpointSource ?? "energy",
      decision_ms: Math.max(0, turnEndMs - callerStopMs),
      queue_ms: Math.max(0, started - callStartedAt - turnEndMs),
      stt_ms: sttMs,
      reply_ms: 0,
      agent_ms: null,
      tts_ttfb_ms: null,
      tts_ms: 0,
      play_ms: 0,
      heard_ms: null,
      frame_ms: frameCountStart < frames
        ? Math.round((pipeline.pushTotal - frameStart) / (frames - frameCountStart))
        : 0,
      tts_start_ms: null,
      tts_first_audio_ms: null,
    };
    sendTranscript(peerId, "caller", transcript, true).catch((error) => log.warn("transcript send failed", { error: String(error) }));
    const replyStart = Date.now();
    const forwarded = await forward(transcript);
    const reply = forwarded.text;
    if (!reply) return;
    const replyMs = Date.now() - replyStart;
    lat.reply_ms = replyMs;
    lat.agent_ms = forwarded.agent_ms;
    log.info("reply", { reply, peer_id: peerId, trace, reply_ms: replyMs, agent_ms: forwarded.agent_ms });
    sendTranscript(peerId, "agent", spokenText(reply), true).catch((error) => log.warn("transcript send failed", { error: String(error) }));
    const playStart = Date.now();
    await speak(reply, peerId, lat);
    const playMs = Date.now() - playStart;
    // Observation record: the agent turn is the delivery window (TTS + posting),
    // approximating when the caller hears the agent.
    recorder.addTurn({ text: spokenText(reply), role: "agent", started_ms: playStart - callStartedAt, duration_ms: playMs });
    lat.tts_ms = playMs;
    lat.tts_ttfb_ms = lat.tts_first_audio_ms === null ? null : lat.tts_first_audio_ms - lat.tts_start_ms;
    lat.heard_ms = lat.tts_first_audio_ms === null ? null : lat.tts_first_audio_ms - callerStopMs;
    const { tts_start_ms, tts_first_audio_ms, ...ledger } = lat;
    recorder.recordLatency(ledger);
    log.info("turn timing", {
      stt_ms: sttMs,
      reply_ms: replyMs,
      agent_ms: ledger.agent_ms,
      total_ms: Date.now() - started,
      decision_ms: ledger.decision_ms,
      queue_ms: ledger.queue_ms,
      endpoint: ledger.endpoint_source,
      tts_ttfb_ms: ledger.tts_ttfb_ms,
      tts_ms: ledger.tts_ms,
      play_ms: ledger.play_ms,
      heard_ms: ledger.heard_ms,
      frame_ms: ledger.frame_ms,
    });
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
      const { turns, ...latency } = record.latency;
      log.info("call latency", { call_id: record.call_id, ...latency, turns: turns.length });
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
              const row = botStateRow(botSpeech.speaking, sinceOnset, sinceOnset, sinceStop);
              for (const f of await model.chunk(chunk, [...row, ...row])) {
                const d = decider.onFrame(f.intent, f.vad);
                if (d.kind !== "none") {
                  recorder.recordBcdEvent(d.kind, now, d.p);
                  log.info("bcd", { kind: d.kind, p: d.p });
                }
              }
            }
          }).catch((error) => log.warn("bcd", { error: String(error) }));
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
