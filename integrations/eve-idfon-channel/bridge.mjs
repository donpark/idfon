#!/usr/bin/env node
import { createConnection } from "node:net";
import { createServer } from "node:http";

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) args.set(process.argv[i], process.argv[i + 1]);
const socketPath = args.get("--socket");
const targetUrl = args.get("--target");
const secret = args.get("--secret");
const port = Number(args.get("--port"));
if (!socketPath || !targetUrl || !secret || !Number.isInteger(port)) {
  console.error("usage: bridge.mjs --socket PATH --target URL --secret VALUE --port PORT");
  process.exit(2);
}

const holder = createConnection(socketPath);
let input = Buffer.alloc(0);
const pending = new Map();
let writeTail = Promise.resolve();

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
    if (value.type === "turn.in") {
      fetch(`${targetUrl}/idfon/turn`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-idfon-channel-secret": secret },
        body: JSON.stringify(value),
      }).catch((error) => console.error(`[idfon-eve-channel] turn delivery failed: ${error}`));
    } else if (value.type === "reply.ack") {
      const waiter = pending.get(value.in_reply_to);
      if (waiter) {
        pending.delete(value.in_reply_to);
        waiter.resolve(value);
      }
    } else if (value.type === "error") {
      for (const [key, waiter] of pending) {
        pending.delete(key);
        waiter.reject(new Error(`${value.code}: ${value.message}`));
      }
      console.error(`[idfon-eve-channel] holder error: ${value.code}: ${value.message}`);
    }
  }
}

holder.on("data", (chunk) => {
  input = Buffer.concat([input, chunk]);
  try { processFrames(); } catch (error) { console.error(error); holder.destroy(error); }
});
holder.on("error", (error) => { console.error(`[idfon-eve-channel] holder IPC: ${error}`); process.exitCode = 1; });
holder.on("close", () => process.exitCode ||= 1);

const server = createServer(async (request, response) => {
  if (request.method !== "POST" || request.url !== "/reply") {
    response.writeHead(request.url === "/health" ? 200 : 404);
    response.end(request.url === "/health" ? "ok\n" : "not found\n");
    return;
  }
  if (request.headers["x-idfon-channel-secret"] !== secret) {
    response.writeHead(401); response.end("unauthorized\n"); return;
  }
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const body = JSON.parse(Buffer.concat(chunks));
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
server.listen(port, "127.0.0.1", () => console.error(`[idfon-eve-channel] bridge listening on ${port}`));
