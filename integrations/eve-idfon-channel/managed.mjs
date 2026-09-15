#!/usr/bin/env node
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const bridge = resolve(here, "bridge.mjs");
const args = process.argv.slice(2);
const values = new Map();
const allows = [];
for (let i = 0; i < args.length; i += 1) {
  const key = args[i];
  if (key === "--allow") allows.push(args[++i]);
  else if (key.startsWith("--")) values.set(key, args[++i]);
  else usage(`unexpected argument ${key}`);
}

const holderCommand = values.get("--holder-command") || process.env.IDFON_EVE_CHANNEL_HOLDER;
const target = values.get("--target");
const secret = values.get("--secret");
const socket = values.get("--socket");
const keyFile = values.get("--key-file");
const blobDir = values.get("--blob-dir") || resolve(dirname(socket || "."), "blobs");
const port = Number(values.get("--port"));
const liveTtlSecs = Number(values.get("--live-ttl-secs") || 3600);
if (!holderCommand || !target || !secret || !socket || !keyFile || !Number.isInteger(port) || port < 1 || port > 65535) {
  usage("--holder-command, --target, --secret, --socket, --key-file, and --port are required");
}
if (!Number.isInteger(liveTtlSecs) || liveTtlSecs < 1) usage("--live-ttl-secs must be a positive integer");
const targetUrl = new URL(target);
if (!["localhost", "127.0.0.1", "[::1]", "::1"].includes(targetUrl.hostname)) {
  usage("--target must point to the local Eve HTTP server");
}

function usage(error) {
  if (error) console.error(`idfon-eve-channel managed: ${error}`);
  console.error("usage: managed.mjs --holder-command PATH --target URL --secret VALUE --socket PATH --key-file FILE --port PORT [--blob-dir PATH] [--allow PEER_ID]...");
  process.exit(2);
}

const lockPath = `${socket}.lock`;
let lockHeld = false;
let holder;
let bridgeProcess;
let stopping = false;

async function acquireLock() {
  await fs.mkdir(dirname(socket), { recursive: true });
  for (;;) {
    try {
      await fs.writeFile(lockPath, `${process.pid}\n`, { flag: "wx" });
      lockHeld = true;
      return;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      try {
        const pid = Number((await fs.readFile(lockPath, "utf8")).trim());
        process.kill(pid, 0);
        throw new Error(`managed holder already running (pid ${pid})`);
      } catch (probe) {
        if (probe?.message?.startsWith("managed holder already running")) throw probe;
        await fs.rm(lockPath, { force: true });
      }
    }
  }
}

function waitForEndpoint(child) {
  return new Promise((resolveTicket, reject) => {
    let buffer = "";
    const onData = (chunk) => {
      buffer += chunk.toString();
      for (;;) {
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        try {
          const ticket = JSON.parse(line);
          child.stdout.off("data", onData);
          resolveTicket(ticket);
          if (buffer) process.stdout.write(buffer);
          return;
        } catch {
          process.stdout.write(`${line}\n`);
        }
      }
    };
    child.stdout.on("data", onData);
    child.once("error", reject);
    child.once("exit", (code, signal) => reject(new Error(`holder exited before startup (${code ?? signal})`)));
  });
}

function stop(child) {
  return new Promise((resolveStop) => {
    if (!child || child.exitCode !== null || child.signalCode !== null) return resolveStop();
    const timer = setTimeout(() => child.kill("SIGKILL"), 3000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolveStop();
    });
    child.kill("SIGTERM");
  });
}

async function cleanup(code = 0) {
  if (stopping) return;
  stopping = true;
  await stop(bridgeProcess);
  await stop(holder);
  if (lockHeld) await fs.rm(lockPath, { force: true });
  process.exitCode = code;
}

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.once(signal, () => { void cleanup(0); });
}

try {
  await acquireLock();
  const holderArgs = ["--key-file", keyFile, "serve", "--socket", socket, "--blob-dir", blobDir, "--live-ttl-secs", String(liveTtlSecs)];
  for (const peer of allows) holderArgs.push("--allow", peer);
  holder = spawn(holderCommand, holderArgs, { stdio: ["ignore", "pipe", "inherit"] });
  const ticket = await waitForEndpoint(holder);
  process.stdout.write(`${JSON.stringify(ticket)}\n`);
  bridgeProcess = spawn(process.execPath, [bridge, "--socket", socket, "--target", target, "--secret", secret, "--port", String(port)], { stdio: "inherit" });
  bridgeProcess.once("exit", (code) => {
    if (!stopping && code !== 0) void cleanup(code || 1);
  });
  holder.once("exit", (code) => {
    if (!stopping) {
      console.error(`[idfon-eve-channel] holder exited (${code ?? "signal"})`);
      void cleanup(code || 1);
    }
  });
} catch (error) {
  console.error(`[idfon-eve-channel] managed startup failed: ${error.message}`);
  await cleanup(1);
}
