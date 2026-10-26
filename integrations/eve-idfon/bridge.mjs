#!/usr/bin/env node
import { createConnection } from "node:net";
import { createServer } from "node:http";
import { logger } from "./log.mjs";

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i], process.argv[i + 1]);
const socketPath = args.get("--socket");
const targetUrl = args.get("--target");
const secret = args.get("--secret");
const port = Number(args.get("--port"));
const MAX_BODY_BYTES = 8 * 1024 * 1024;
if (!socketPath || !targetUrl || !secret || !Number.isInteger(port)) {
  console.error("usage: bridge.mjs --socket PATH --target URL --secret VALUE --port PORT");
  process.exit(2);
}

const holder = createConnection(socketPath);
const log = logger("idfon.bridge");
let input = Buffer.alloc(0);
const pending = new Map();
// Outbound sends awaiting a reply turn (the intro flow: ask the target agent
// for a card and hold the caller's turn open until it arrives). Keyed by the
// `reply_to` id the two agents carry in the request/reply text.
const pendingReplies = new Map();
// Reply correlation (`docs/voice-agent-loop-contract.md`): a turn request
// whose context ends `Turn: <id>` is answered with that id echoed as the
// reply's `speak.correlation_id`, so the caller can match replies to turns
// exactly. The echo is applied here — mechanically — never left to the model.
const turnOf = new Map();

function turnIdOf(context) {
  const match = typeof context === "string" && /(?:^|\n)Turn: ([^\s]+)/.exec(context);
  return match ? match[1] : null;
}

function withSpeakCorrelation(text, correlationId) {
  if (!correlationId || typeof text !== "string" || !text.includes("IDFON-SPEAK/1")) return text;
  // Envelope bodies are compact single-line JSON from our tool emitters.
  return text.replace(/IDFON-SPEAK\/1\n(\{[^\n]*\})/g, (whole, json) => {
    try {
      const envelope = JSON.parse(json);
      if (envelope.correlation_id == null) envelope.correlation_id = correlationId;
      return `IDFON-SPEAK/1\n${JSON.stringify(envelope)}`;
    } catch {
      return whole;
    }
  });
}
const roomMembers = new Map();
// Live-call caller-audio SSE subscribers (standalone TS voice agents).
const sseClients = new Set();
let writeTail = Promise.resolve();
let nextRequestId = 1;
// Voice pipeline this holder runs, pushed once at startup (`voice.info`).
// Served to the agent as `/voice/info` for introspection.
let voiceInfo = null;

function frame(value) {
  const payload = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(payload.length);
  return Buffer.concat([header, payload]);
}

function write(value) {
  writeTail = writeTail.then(() => new Promise((resolve, reject) => {
    if (!holder.write(frame(value), (error) => error ? reject(error) : resolve())) {
      holder.once("drain", resolve);
    }
  }));
  return writeTail;
}

function processFrames() {
  while (input.length >= 4) {
    const size = input.readUInt32LE(0);
    if (size > 1024 * 1024) throw new Error("holder IPC frame too large");
    if (input.length < size + 4) return;
    const value = JSON.parse(input.subarray(4, size + 4));
    input = input.subarray(size + 4);
    if (value.type === "turn.in" || value.type === "input.in" || value.type === "status.in") {
      log.info("forwarding to agent", {
        type: value.type,
        message_id: value.message_id,
        peer_id: value.peer_id,
        conversation: value.conversation,
        trace: value.trace,
      });
      // A reply to an in-flight intro is consumed here, not forwarded as a turn.
      if (value.type === "turn.in") {
        const match = /(?:^|\n)reply_to=([A-Za-z0-9._-]+)/.exec(value.text ?? "");
        const waiter = match && pendingReplies.get(match[1]);
        if (waiter) {
          pendingReplies.delete(match[1]);
          waiter.resolve(value);
          continue;
        }
      }
      const path = value.type === "turn.in" ? "/idfon/turn" : value.type === "input.in" ? "/idfon/input" : "/idfon/status";
      if (value.type === "turn.in" && value.message_id) {
        const turnId = turnIdOf(value.context);
        if (turnId) turnOf.set(value.message_id, turnId);
        if (turnOf.size > 5000) turnOf.clear(); // unreplied turns never drain
      }
      fetch(`${targetUrl}${path}`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-idfon-channel-secret": secret },
        body: JSON.stringify(value),
      }).then(async (response) => {
        // Boundary wide event: the agent edge's outcome. A non-2xx here is the
        // usual cause of "the holder got a turn but no reply came back" — the
        // holder's seam span only records that nothing was returned.
        if (!response.ok) {
          log.error("agent rejected turn", {
            type: value.type, message_id: value.message_id, peer_id: value.peer_id,
            trace: value.trace, status: response.status,
            body: (await response.text()).slice(0, 500),
          });
        }
      }).catch((error) => log.error("delivery failed", { type: value.type, message_id: value.message_id, peer_id: value.peer_id, trace: value.trace, error: String(error) }));
    } else if (value.type === "audio.frame") {
      const line = `data: ${JSON.stringify(value)}\n\n`;
      for (const client of sseClients) {
        try { client.write(line); } catch { sseClients.delete(client); }
      }
    } else if (value.type === "voice.info") {
      voiceInfo = value.info ?? null;
      log.info("voice pipeline info received", { mode: voiceInfo?.mode, backend: voiceInfo?.backend });
    } else if (value.type === "reply.ack" || value.type === "blob.result" || value.type === "blob.put.result" || value.type === "records.drain.result" || value.type === "stream.append.result" || value.type === "audio.append.result" || value.type === "ticket.issue.result" || value.type === "input.ack" || value.type === "peer.ack" || value.type === "status.ack" || value.type === "live.publish.result" || value.type === "live.stop.result") {
      const key = value.type === "reply.ack" ? value.in_reply_to : value.request_id;
      const waiter = pending.get(key);
      if (waiter) {
        pending.delete(key);
        waiter.resolve(value);
      }
    } else if (value.type === "error") {
      for (const [key, waiter] of pending) {
        pending.delete(key);
        waiter.reject(new Error(`${value.code}: ${value.message}`));
      }
      log.error("holder error", { code: value.code, message: value.message });
    }
  }
}

holder.on("data", (chunk) => {
  input = Buffer.concat([input, chunk]);
  try { processFrames(); } catch (error) { log.error("frame processing failed", { error: String(error) }); holder.destroy(error); }
});
holder.on("error", (error) => { log.error("holder ipc error", { error: String(error) }); process.exitCode = 1; });
holder.on("close", () => process.exitCode ||= 1);

const server = createServer(async (request, response) => {
  // Live-call caller audio: an SSE stream a standalone TS voice agent reads.
  if (request.method === "GET" && request.url === "/live/stream") {
    response.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    response.write(": connected\n\n");
    sseClients.add(response);
    request.on("close", () => sseClients.delete(response));
    return;
  }
  if (request.method !== "POST" || !["/reply", "/room/member", "/room/members", "/blob", "/blob/put", "/records/drain", "/voice/info", "/stream/append", "/live/audio", "/input", "/send", "/card", "/status", "/live/publish", "/live/stop"].includes(request.url)) {
    response.writeHead(request.url === "/health" ? 200 : 404);
    response.end(request.url === "/health" ? "ok\n" : "not found\n");
    return;
  }
  if (request.headers["x-idfon-channel-secret"] !== secret) {
    response.writeHead(401); response.end("unauthorized\n"); return;
  }
  const chunks = [];
  let bodyBytes = 0;
  for await (const chunk of request) {
    bodyBytes += chunk.length;
    if (bodyBytes > MAX_BODY_BYTES) {
      response.writeHead(413); response.end("request too large\n"); return;
    }
    chunks.push(chunk);
  }
  let body;
  try {
    body = JSON.parse(Buffer.concat(chunks));
  } catch {
    response.writeHead(400); response.end("invalid JSON\n"); return;
  }
  if (request.url === "/room/member") {
    if (typeof body.conversation !== "string" || !body.conversation ||
        typeof body.peer_id !== "string" || typeof body.endpoint_id !== "string" ||
        typeof body.message_id !== "string") {
      response.writeHead(400); response.end("invalid room member\n"); return;
    }
    const members = roomMembers.get(body.conversation) ?? new Map();
    members.set(body.peer_id, {
      peer_id: body.peer_id,
      endpoint_id: body.endpoint_id,
      message_id: body.message_id,
    });
    roomMembers.set(body.conversation, members);
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ members: [...members.values()] }));
    return;
  }
  if (request.url === "/room/members") {
    if (typeof body.conversation !== "string" || !body.conversation) {
      response.writeHead(400); response.end("invalid room members request\n"); return;
    }
    const members = [...(roomMembers.get(body.conversation)?.values() ?? [])];
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ members }));
    return;
  }
  if (request.url === "/send") {
    // The capability ticket is optional: holders attach only grants whose
    // issuer is the target, and a ticketless message rides the receiver's
    // signature + known-peer gate. When present it must be an object.
    if (typeof body.peer_id !== "string" || typeof body.endpoint_id !== "string" ||
        typeof body.text !== "string" || !body.text ||
        (body.capability_ticket != null &&
         (typeof body.capability_ticket !== "object" || Array.isArray(body.capability_ticket)))) {
      response.writeHead(400); response.end("invalid peer send\n"); return;
    }
    const requestId = `peer-${nextRequestId++}`;
    const awaitReply = body.await_reply === true;
    const replyTo = typeof body.reply_to === "string" && body.reply_to ? body.reply_to : null;
    if (awaitReply && !replyTo) {
      response.writeHead(400); response.end("reply_to is required with await_reply\n"); return;
    }
    const resultPromise = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    let replyPromise = null;
    if (awaitReply) {
      const timeoutMs = Number(body.reply_timeout_ms) || 60_000;
      // `local: true` — the voice engine wraps THIS instance's agent: the
      // carrier refuses "Connecting to ourself is not supported", so the turn
      // goes to the local agent and the reply resolves here when it POSTs
      // /reply (keyed by the agent's in_reply_to compound).
      const local = body.local === true;
      const localId = `local-${nextRequestId++}`;
      const replyKey = local ? `${localId}|${localId}|${body.peer_id}` : replyTo;
      replyPromise = new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pendingReplies.delete(replyKey);
          reject(new Error("timed out waiting for reply"));
        }, timeoutMs);
        pendingReplies.set(replyKey, {
          resolve: (value) => { clearTimeout(timer); resolve(value); },
          reject: (error) => { clearTimeout(timer); reject(error); },
        });
      });
      if (local) {
        // No holder request is made for local sends: drop the unused waiter
        // (a later holder error frame rejects every pending waiter — an
        // orphan here was an unhandled rejection that killed the bridge).
        pending.delete(requestId)
        resultPromise.catch(() => {})
        try {
          await fetch(`${targetUrl}/idfon/turn`, {
            method: "POST",
            headers: { "content-type": "application/json", "x-idfon-channel-secret": secret },
            body: JSON.stringify({
              message_id: localId, peer_id: body.peer_id, endpoint_id: body.endpoint_id,
              idempotency_key: localId, text: body.text, trace: body.trace,
              context: body.context,
            }),
          }).then(async (r) => {
            if (!r.ok) log.error("local turn rejected", { status: r.status, body: (await r.text()).slice(0, 300) });
          });
        } catch (error) {
          log.error("local turn delivery failed", { error: String(error) });
        }
        const turnId = turnIdOf(body.context);
        if (turnId) turnOf.set(localId, turnId);
        try {
          const reply = await replyPromise;
          response.writeHead(200, { "content-type": "application/json" });
          response.end(JSON.stringify({ ok: true, reply }));
        } catch (error) {
          pendingReplies.delete(replyKey);
          response.writeHead(504, { "content-type": "application/json" });
          response.end(JSON.stringify({ error: String(error) }));
        }
        return;
      }
    }
    try {
      await write({
        type: "peer.send",
        request_id: requestId,
        peer_id: body.peer_id,
        endpoint_id: body.endpoint_id,
        conversation: body.conversation,
        text: body.text,
        capability_ticket: body.capability_ticket,
        a2a_depth: body.a2a_depth ?? 0,
      });
      const result = await resultPromise;
      const reply = awaitReply ? await replyPromise : undefined;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(reply ? { ...result, reply } : result));
    } catch (error) {
      pending.delete(requestId);
      if (replyTo) pendingReplies.delete(replyTo);
      // The send already failed; don't let the still-armed reply timer reject
      // an unobserved promise and take the whole bridge down.
      if (replyPromise) replyPromise.catch(() => {});
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  // The agent's own holder signs a fresh, subject-bound "business card"
  // (endpoint address + capability ticket) for `subject`.
  if (request.url === "/card") {
    if (typeof body.subject !== "string" || !body.subject) {
      response.writeHead(400); response.end("invalid card request\n"); return;
    }
    const requestId = `card-${nextRequestId++}`;
    const resultPromise = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    try {
      await write({
        type: "ticket.issue",
        request_id: requestId,
        subject: body.subject,
        capabilities: Array.isArray(body.capabilities) ? body.capabilities : [],
      });
      const result = await resultPromise;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(result));
    } catch (error) {
      pending.delete(requestId);
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  if (request.url === "/live/publish") {
    if (typeof body.path !== "string" || !body.path || typeof body.name !== "string" || !body.name) {
      response.writeHead(400); response.end("invalid live publish request\n"); return;
    }
    const requestId = `live-publish-${nextRequestId++}`;
    const resultPromise = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    try {
      await write({
        type: "live.publish",
        request_id: requestId,
        path: body.path,
        loop_playback: body.loop_playback ?? false,
        name: body.name,
        relay: body.relay ?? true,
        video: body.video ?? false,
        quality: body.quality,
      });
      const result = await resultPromise;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(result));
    } catch (error) {
      pending.delete(requestId);
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  if (request.url === "/live/stop") {
    if (typeof body.id !== "string" || !body.id) {
      response.writeHead(400); response.end("invalid live stop request\n"); return;
    }
    const requestId = `live-stop-${nextRequestId++}`;
    const resultPromise = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    try {
      await write({ type: "live.stop", request_id: requestId, id: body.id });
      const result = await resultPromise;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(result));
    } catch (error) {
      pending.delete(requestId);
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  if (request.url === "/status") {
    if (typeof body.in_reply_to !== "string" || typeof body.event !== "string" ||
        body.data === undefined) {
      response.writeHead(400); response.end("invalid status\n"); return;
    }
    const requestId = `status-${nextRequestId++}`;
    const ack = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    try {
      await write({
        type: "status.out",
        request_id: requestId,
        in_reply_to: body.in_reply_to,
        event: body.event,
        data: body.data,
      });
      const result = await ack;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(result));
    } catch (error) {
      pending.delete(requestId);
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  if (request.url === "/input") {
    if (typeof body.request_id !== "string" || typeof body.peer_id !== "string" ||
        typeof body.endpoint_id !== "string" || !Array.isArray(body.requests)) {
      response.writeHead(400); response.end("invalid input request\n"); return;
    }
    const resultPromise = new Promise((resolve, reject) => pending.set(body.request_id, { resolve, reject }));
    try {
      await write({
        type: "input.out",
        request_id: body.request_id,
        peer_id: body.peer_id,
        endpoint_id: body.endpoint_id,
        conversation: body.conversation,
        requests: body.requests,
      });
      const result = await resultPromise;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(result));
    } catch (error) {
      pending.delete(body.request_id);
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  if (request.url === "/blob/put") {
    if (typeof body.bytes_base64 !== "string" || !body.bytes_base64) {
      response.writeHead(400); response.end("invalid blob data\n"); return;
    }
    const requestId = `blob-put-${nextRequestId++}`;
    const resultPromise = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    try {
      await write({ type: "blob.put", request_id: requestId, bytes_base64: body.bytes_base64 });
      const result = await resultPromise;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(result));
    } catch (error) {
      pending.delete(requestId);
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  if (request.url === "/stream/append") {
    if (typeof body.turn_id !== "string" || typeof body.step_index !== "number" ||
        typeof body.sequence !== "number" || typeof body.text !== "string") {
      response.writeHead(400); response.end("invalid stream append\n"); return;
    }
    const requestId = `stream-append-${nextRequestId++}`;
    const resultPromise = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    try {
      await write({
        type: "stream.append",
        request_id: requestId,
        peer_id: typeof body.peer_id === "string" ? body.peer_id : undefined,
        turn_id: body.turn_id,
        step_index: body.step_index,
        sequence: body.sequence,
        text: body.text,
      });
      const result = await resultPromise;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(result));
    } catch (error) {
      pending.delete(requestId);
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  if (request.url === "/live/audio") {
    if (typeof body.peer_id !== "string" || typeof body.pcm_base64 !== "string") {
      response.writeHead(400); response.end("invalid audio append\n"); return;
    }
    const requestId = `audio-append-${nextRequestId++}`;
    const resultPromise = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    try {
      await write({
        type: "audio.append",
        request_id: requestId,
        peer_id: body.peer_id,
        pcm_base64: body.pcm_base64,
      });
      const result = await resultPromise;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(result));
    } catch (error) {
      pending.delete(requestId);
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  if (request.url === "/voice/info") {
    // The holder's startup push lists the CLIENT's on-device options; the live
    // engine POSTs its real pipeline here so the info screen is the truth.
    if (body && (body.options || body.engine)) {
      voiceInfo = { ...(voiceInfo ?? {}), ...body };
      log.info("voice pipeline updated by engine", { engine: body.engine });
      // One hop to the truth: forward the declaration to the holder, whose
      // advertised `idfon.json` is what the phone's Speech pickers read.
      if (Array.isArray(body.options)) {
        write({ type: "voice.options", options: body.options }).catch((error) =>
          log.warn("voice options forward failed", { error: String(error) }));
      }
    }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(voiceInfo ?? {}));
    return;
  }
  if (request.url === "/records/drain") {
    if (typeof body.peer_id !== "string" || !body.peer_id || typeof body.turn_id !== "string") {
      response.writeHead(400); response.end("invalid records drain request\n"); return;
    }
    const requestId = `records-drain-${nextRequestId++}`;
    const resultPromise = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    try {
      await write({ type: "records.drain", request_id: requestId, peer_id: body.peer_id, turn_id: body.turn_id });
      const result = await resultPromise;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(result));
    } catch (error) {
      pending.delete(requestId);
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  if (request.url === "/blob") {
    if (typeof body.ticket !== "string") {
      response.writeHead(400); response.end("invalid blob request\n"); return;
    }
    const requestId = `blob-${nextRequestId++}`;
    const resultPromise = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
    try {
      await write({ type: "blob.fetch", request_id: requestId, ticket: body.ticket });
      const result = await resultPromise;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(result));
    } catch (error) {
      pending.delete(requestId);
      response.writeHead(502); response.end(`${error}\n`);
    }
    return;
  }
  if (!body.in_reply_to || typeof body.text !== "string") {
    response.writeHead(400); response.end("invalid reply\n"); return;
  }
  // Boundary wide event: the agent produced a reply for a turn. Absence of
  // this line after a `forwarding to agent` is "the agent never finished".
  log.info("agent replied", { in_reply_to: body.in_reply_to, chars: body.text.length });
  const replyText = withSpeakCorrelation(body.text, turnOf.get(body.in_reply_to));
  turnOf.delete(body.in_reply_to);
  // A local turn (a voice engine wrapping this instance's agent) waits on the
  // /reply itself — resolve it here and skip the holder round trip.
  const localWaiter = pendingReplies.get(body.in_reply_to);
  if (localWaiter) {
    pendingReplies.delete(body.in_reply_to);
    localWaiter.resolve({ text: replyText });
    response.writeHead(200, { "content-type": "application/json" });
    response.end("{}");
    return;
  }
  const ack = new Promise((resolve, reject) => pending.set(body.in_reply_to, { resolve, reject }));
  try {
    await write({ type: "reply.out", in_reply_to: body.in_reply_to, text: replyText });
    const result = await ack;
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(result));
  } catch (error) {
    pending.delete(body.in_reply_to);
    response.writeHead(502); response.end(`${error}\n`);
  }
});
server.listen(port, "127.0.0.1", () => log.info("bridge listening", { port }));
