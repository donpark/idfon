#!/usr/bin/env node
// TYGER relay for idfon live calls (docs/voice-tyger.md, P0a / Shape 1): caller audio
// -> a tyger-s2s stack over its /ws -> caller. The tyger stack owns turn-taking (EARS),
// the reply and the speech (MOUTH); this process is only the transport adapter.
//
//   IDFON_BRIDGE_URL=http://127.0.0.1:18766  node tyger-relay.mjs            # behind a served agent
//   node tyger-relay.mjs --smoke in.wav --out out.wav                       # no bridge: drive it from a WAV
//
// in.wav must be 24 kHz mono s16 (what the idfon live leg carries). --smoke feeds it in
// real time and writes everything the caller would hear to --out.
//
// tyger's /ws wire (their README "The protocol"; little-endian):
//   mic -> server: [i32 reply id][i32 reply sample at 24 kHz, -1: none][i16 @16 kHz], 20 ms
//     blocks. The tag is the reply sample the caller was hearing when the block started —
//     the second ear their turn-taker needs. Backchannel audio (id 0) is played but never
//     tagged.
//   server -> us:  [i32 reply id, 0: backchannel][i16 @24 kHz]
//   text:  played:<id>:<samples> once a reply has played out (ends the agent's turn),
//     plus reset, voice:<name>, set:<attr>:<value>. On `barge` stop playing at once.
//
// The caller device is our playback clock and we never see its playhead, so the tags are
// scheduled on our own post timeline with a fixed playback lag (TYGER_TAG_LAG_MS) standing
// in for the device's buffer. shortcut: tags and `played:` assume the caller plays at 1x
// starting when we post; swap for real playhead reports if false barge-ins show up.
//
// Env: IDFON_BRIDGE_URL / IDFON_BRIDGE_SECRET — the served agent's bridge (backend=relay);
//      TYGER_URL (default ws://127.0.0.1:7860/ws), TYGER_API_SECRET (omit when unset there);
//      TYGER_VOICE — voice:<name> at start; TYGER_SET — "ep_thr:0.91,barge_thr:0.5";
//      TYGER_TAG_LAG_MS (default 0).

import { createHmac, randomUUID } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const bridge = process.env.IDFON_BRIDGE_URL || "http://127.0.0.1:18766";
const secret = process.env.IDFON_BRIDGE_SECRET || "m2-test-secret";
const tygerUrl = process.env.TYGER_URL || "ws://127.0.0.1:7860/ws";
const RATE = 24_000, EARS_RATE = 16_000, BLOCK = 320; // 20 ms at 16 kHz
const LEAD_IN_MS = 40; // the browser client's play lead-in
const TAG_LAG_MS = Number(process.env.TYGER_TAG_LAG_MS || 0);

const log = ((service) => {
  const emit = (level, message, fields) => {
    const record = { ts: new Date().toISOString(), level, service, target: "idfon.tyger-relay", message };
    if (fields) for (const [k, v] of Object.entries(fields)) if (v != null && v !== "") record[k] = v;
    process.stderr.write(JSON.stringify(record) + "\n");
  };
  return { info: (m, f) => emit("info", m, f), warn: (m, f) => emit("warn", m, f), error: (m, f) => emit("error", m, f) };
})(process.env.IDFON_SERVICE_NAME ?? "eve-idfon-voice");

// HS256 JWT, one per conversation (their app/ears/access.py: aud "tyger", a fresh jti).
function token() {
  const b64 = (b) => Buffer.from(b).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const head = b64(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const claims = b64(JSON.stringify({ aud: "tyger", jti: randomUUID(), iat: now, exp: now + 60 }));
  const sig = createHmac("sha256", process.env.TYGER_API_SECRET).update(`${head}.${claims}`).digest("base64url");
  return `${head}.${claims}.${sig}`;
}

// 24 -> 16 kHz, continuous across frames: linear interpolation on a fractional position,
// the same algorithm as their page's mic worklet (web/lib/tyger/client.ts).
function makeResampler() {
  const step = RATE / EARS_RATE;
  let pos = -1, prev = 0;
  return (x) => {
    const out = [];
    if (pos < -1) pos = 0; // a gap in the stream: start over here
    for (;;) {
      const p = Math.floor(pos), i = p; // the input sample at or before the next output sample
      if (i + 1 >= x.length) break; // its successor comes with the next chunk
      const a = i < 0 ? prev : x[i], f = pos - p;
      out.push(a + (x[i + 1] - a) * f);
      pos += step;
    }
    prev = x[x.length - 1];
    pos -= x.length; // carry into the next chunk's index space
    return out;
  };
}

// One conversation with tyger's /ws. `play(id, samples16)` pushes reply audio (24 kHz s16)
// to the caller; the tag/played bookkeeping mirrors web/lib/tyger/client.ts.
class Call {
  constructor({ play }) {
    this.play = play;
    this.ws = null;
    this.resample = makeResampler();
    this.pcm = []; // resampled mic samples waiting for a 320-sample block
    this.sched = []; // played chunks: { id, t0, t1, first }
    this.queued = {}; // reply id -> its samples sent to the caller
    this.lastId = 0;
    this.nextPlay = 0;
    this.drainTimer = null;
    this.stats = { micBlocks: 0, replies: 0, backchannels: 0, replySamples: 0, playedReports: 0 };
  }

  async open() {
    const url = new URL(tygerUrl);
    if (url.protocol === "https:") url.protocol = "wss:";
    else if (url.protocol === "http:") url.protocol = "ws:";
    if (process.env.TYGER_API_SECRET) url.searchParams.set("token", token());
    const ws = (this.ws = new WebSocket(url.toString()));
    ws.binaryType = "arraybuffer";
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = () => reject(new Error(`can't reach tyger at ${url}`));
    });
    ws.onmessage = (ev) => {
      if (ev.data instanceof ArrayBuffer) this.onAudio(ev.data);
      else this.onEvent(JSON.parse(ev.data));
    };
    ws.onclose = (ev) => {
      log.warn("tyger closed", { reason: ev.reason || "(none)" });
      this.onClose?.(ev.reason || "");
    };
    log.info("tyger open", { url: tygerUrl });
    return this;
  }

  onEvent(m) {
    switch (m.type) {
      case "ready":
        log.info("tyger ready", { voices: (m.voices || []).join(","), max_session_s: m.max_session_s });
        if (process.env.TYGER_VOICE && (m.voices || []).includes(process.env.TYGER_VOICE)) this.send(`voice:${process.env.TYGER_VOICE}`);
        for (const pair of (process.env.TYGER_SET || "").split(",")) {
          const [attr, value] = pair.split(":");
          if (attr && value) this.send(`set:${attr.trim()}:${value.trim()}`);
        }
        break;
      case "endpoint": // a new reply never overlaps the last: stop playing it
        this.stopPlayback();
        log.info("endpoint", { transcript: m.transcript });
        break;
      case "barge": // the caller cut in: stop playing at once
        this.stopPlayback();
        log.info("barge", { played_s: m.played_s });
        break;
      case "turn_done":
        log.info("turn_done", { barged: !!m.barged, ...this.stats });
        break;
      case "backchannel":
      case "backchannel_done":
        log.info(m.type, { text: m.text, aborted: m.aborted });
        break;
      case "busy":
      case "error":
      case "session_end":
        log.warn(`tyger ${m.type}`, { reason: m.reason, error: m.error });
        break;
      default:
        if (m.type !== "partial" && m.type !== "reply" && m.type !== "state") log.info("tyger event", m);
    }
    this.onMessage?.(m);
  }

  send(text) {
    if (this.ws?.readyState === 1) this.ws.send(text);
  }

  // Caller audio: 24 kHz s16 -> 16 kHz -> tagged 20 ms blocks. The tag is what the caller
  // was hearing at the block's start on our post timeline, lagged by TAG_LAG_MS.
  pushMic(pcm24) {
    this.pcm.push(...this.resample(pcm24));
    while (this.pcm.length >= BLOCK) {
      const block = this.pcm.splice(0, BLOCK);
      const [id, at] = this.tagAt(Date.now() - TAG_LAG_MS);
      const buf = Buffer.alloc(8 + BLOCK * 2);
      buf.writeInt32LE(id, 0);
      buf.writeInt32LE(at, 4);
      for (let i = 0; i < BLOCK; i++) buf.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(block[i]))), 8 + i * 2);
      if (this.ws?.readyState === 1) this.ws.send(buf);
      this.stats.micBlocks++;
    }
  }

  // [reply id, its sample the caller hears at time t] — client.ts's tagAt: the scheduled
  // chunk under the playhead, else [lastId, -1].
  tagAt(t) {
    this.sched = this.sched.filter((c) => c.t1 > t - 2000);
    for (const c of this.sched) if (c.t0 <= t && t < c.t1) return [c.id, c.first + Math.floor(((t - c.t0) / 1000) * RATE)];
    return [this.lastId, -1];
  }

  // [reply id, 0: backchannel][i16 @24 kHz]: play it on the caller, tag the non-zero ids.
  onAudio(ab) {
    const raw = Buffer.from(ab);
    const id = raw.readInt32LE(0);
    const samples = Array.from({ length: (raw.length - 4) / 2 }, (_, i) => raw.readInt16LE(4 + i * 2));
    this.play(id, samples);
    if (id === 0) {
      this.stats.backchannels++;
      return;
    }
    const now = Date.now();
    const first = this.queued[id] || 0;
    this.queued[id] = first + samples.length;
    this.lastId = id;
    const t0 = this.nextPlay < now ? now + LEAD_IN_MS : this.nextPlay;
    const t1 = t0 + (samples.length / RATE) * 1000;
    this.sched.push({ id, t0, t1, first });
    this.nextPlay = t1;
    this.stats.replies = Math.max(this.stats.replies, id);
    this.stats.replySamples += samples.length;
    // The last chunk queued has played and nothing new arrived: report the reply played.
    clearTimeout(this.drainTimer);
    this.drainTimer = setTimeout(() => {
      if (this.nextPlay <= t1 + 1e-6) {
        this.send(`played:${id}:${this.queued[id]}`);
        this.stats.playedReports++;
      }
    }, Math.max(0, t1 - now));
  }

  stopPlayback() {
    clearTimeout(this.drainTimer);
    this.drainTimer = null;
    this.sched = [];
    this.nextPlay = 0;
  }

  close(reason = "") {
    this.stopPlayback();
    try {
      this.ws?.close();
    } catch {}
    this.ws = null;
    this.onClose?.(reason);
  }
}

// ---- WAV in/out for --smoke (24 kHz mono s16) ----
function readWav(path) {
  const b = readFileSync(path);
  if (b.toString("ascii", 0, 4) !== "RIFF" || b.toString("ascii", 8, 12) !== "WAVE") throw new Error(`${path}: not a WAV`);
  const channels = b.readUInt16LE(22), rate = b.readUInt32LE(24), bits = b.readUInt16LE(34);
  if (channels !== 1 || rate !== RATE || bits !== 16) throw new Error(`${path}: need ${RATE} Hz mono s16, got ${rate} Hz ${channels}ch ${bits}bit`);
  const data = b.indexOf("data");
  return b.subarray(data + 8);
}
function writeWav(path, pcm) {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0); header.writeUInt32LE(36 + pcm.length, 4); header.write("WAVE", 8);
  header.write("fmt ", 12); header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22); header.writeUInt32LE(RATE, 24); header.writeUInt32LE(RATE * 2, 28);
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34); header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  writeFileSync(path, Buffer.concat([header, pcm]));
}

async function main() {
  const smoke = (() => { const i = process.argv.indexOf("--smoke"); return i >= 0 ? process.argv[i + 1] : null; })();
  const outIndex = process.argv.indexOf("--out");
  const outPath = outIndex >= 0 ? process.argv[outIndex + 1] : "tyger-out.wav";
  if (smoke && !smoke.endsWith(".wav")) throw new Error("--smoke needs a 24 kHz mono s16 WAV");

  let play, call;
  if (smoke) {
    const heard = [];
    play = (_id, samples) => heard.push(Buffer.from(Int16Array.from(samples).buffer));
    call = new Call({ play });
    call.onClose = () => {};
    await call.open();
    const pcm = readWav(smoke);
    const frame = (RATE / 50) * 2; // 20 ms of s16
    log.info("smoke: playing", { path: smoke, seconds: (pcm.length / 2 / RATE).toFixed(1) });
    for (let off = 0; off + frame <= pcm.length; off += frame) {
      call.pushMic(Array.from({ length: frame / 2 }, (_, i) => pcm.readInt16LE(off + i * 2)));
      await new Promise((r) => setTimeout(r, 20));
    }
    await new Promise((r) => setTimeout(r, 4000)); // let the last turn finish
    writeWav(outPath, Buffer.concat(heard));
    log.info("smoke: done", { out: outPath, out_seconds: (Buffer.concat(heard).length / 2 / RATE).toFixed(2), ...call.stats });
    call.close("");
    process.exit(0);
  }

  let peerId = null;
  play = async (id, samples) => {
    const pcm = Buffer.from(Int16Array.from(samples).buffer);
    const response = await fetch(`${bridge}/live/audio`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-idfon-channel-secret": secret },
      body: JSON.stringify({ peer_id: peerId, pcm_base64: pcm.toString("base64") }),
    });
    if (!response.ok) log.error("live audio HTTP", { status: response.status, id });
  };

  call = new Call({ play });
  await call.open();
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
      try {
        frame = JSON.parse(line.slice(6));
      } catch {
        continue;
      }
      if (frame.type !== "audio.frame") continue;
      if (peerId && frame.peer_id !== peerId) continue; // one call per relay
      peerId = frame.peer_id;
      const raw = Buffer.from(frame.pcm_base64, "base64");
      call.pushMic(Array.from({ length: raw.length / 2 }, (_, i) => raw.readInt16LE(i * 2)));
    }
  }
  call.close("bridge stream ended");
}

main().catch((error) => {
  log.error("fatal", { error: String(error) });
  process.exit(1);
});
