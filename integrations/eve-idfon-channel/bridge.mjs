#!/usr/bin/env node
import { createConnection } from "node:net";
import { createServer } from "node:http";

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
let input = Buffer.alloc(0);
const pending = new Map();
const roomMembers = new Map();
let writeTail = Promise.resolve();
let nextRequestId = 1;

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
      const path = value.type === "turn.in" ? "/idfon/turn" : value.type === "input.in" ? "/idfon/input" : "/idfon/status";
      fetch(`${targetUrl}${path}`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-idfon-channel-secret": secret },
        body: JSON.stringify(value),
      }).catch((error) => console.error(`[eve-idfon-channel] ${value.type} delivery failed: ${error}`));
    } else if (value.type === "reply.ack" || value.type === "blob.result" || value.type === "blob.put.result" || value.type === "input.ack" || value.type === "peer.ack" || value.type === "status.ack" || value.type === "live.publish.result" || value.type === "live.stop.result") {
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
      console.error(`[eve-idfon-channel] holder error: ${value.code}: ${value.message}`);
    }
  }
}

holder.on("data", (chunk) => {
  input = Buffer.concat([input, chunk]);
  try { processFrames(); } catch (error) { console.error(error); holder.destroy(error); }
});
holder.on("error", (error) => { console.error(`[eve-idfon-channel] holder IPC: ${error}`); process.exitCode = 1; });
holder.on("close", () => process.exitCode ||= 1);

const server = createServer(async (request, response) => {
  if (request.method !== "POST" || !["/reply", "/room/member", "/room/members", "/blob", "/blob/put", "/input", "/send", "/status", "/live/publish", "/live/stop"].includes(request.url)) {
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
    if (typeof body.peer_id !== "string" || typeof body.endpoint_id !== "string" ||
        typeof body.text !== "string" || !body.text || body.capability_ticket == null ||
        typeof body.capability_ticket !== "object" || Array.isArray(body.capability_ticket)) {
      response.writeHead(400); response.end("invalid peer send\n"); return;
    }
    const requestId = `peer-${nextRequestId++}`;
    const resultPromise = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }));
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
  const ack = new Promise((resolve, reject) => pending.set(body.in_reply_to, { resolve, reject }));
  try {
    await write({ type: "reply.out", in_reply_to: body.in_reply_to, text: body.text });
    const result = await ack;
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(result));
  } catch (error) {
    pending.delete(body.in_reply_to);
    response.writeHead(502); response.end(`${error}\n`);
  }
});
server.listen(port, "127.0.0.1", () => console.error(`[eve-idfon-channel] bridge listening on ${port}`));
