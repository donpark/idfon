#!/usr/bin/env node
import { spawn } from "node:child_process";
import { existsSync, promises as fs } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const bridge = resolve(here, "bridge.mjs");
const require = createRequire(import.meta.url);

// The holder ships as per-platform packages (optional dependencies of this
// package), mirroring cli/idfon. --holder-command / EVE_IDFON_HOLDER
// override the lookup.
const holderPackages = {
  "darwin-arm64": "eve-idfon-darwin-arm64",
  "darwin-x64": "eve-idfon-darwin-x64",
  "linux-arm64": "eve-idfon-linux-arm64",
  "linux-x64": "eve-idfon-linux-x64",
  // ponytail: no win32 — the holder IPC is a Unix socket; add a named-pipe
  // transport to idfon-client first, then an eve-idfon-win32-x64 pkg.
};

function resolveHolder() {
  const pkg = holderPackages[`${process.platform}-${process.arch}`];
  if (!pkg) return undefined;
  let dir;
  try {
    dir = dirname(require.resolve(`${pkg}/package.json`));
  } catch {
    // Repo-layout fallback: platform packages sitting at integrations/* from
    // scripts/build-eve.sh (no node_modules install).
    dir = resolve(here, "..", pkg);
  }
  return resolve(dir, "bin", "eve-idfon");
}
const args = process.argv.slice(2);
const values = new Map();
const allows = [];
for (let i = 0; i < args.length; i += 1) {
  const key = args[i];
  if (key === "--allow") allows.push(args[++i]);
  else if (key.startsWith("--")) values.set(key, args[++i]);
  else usage(`unexpected argument ${key}`);
}

const holderCommand =
  values.get("--holder-command") || process.env.EVE_IDFON_HOLDER || resolveHolder();
const target = values.get("--target");
const secret = values.get("--secret");
const socket = values.get("--socket");
const keyFile = values.get("--key-file");
const blobDir = values.get("--blob-dir") || resolve(dirname(socket || "."), "blobs");
const port = Number(values.get("--port"));
const liveTtlSecs = Number(values.get("--live-ttl-secs") || 3600);
if (!holderCommand || !target || !secret || !socket || !keyFile || !Number.isInteger(port) || port < 1 || port > 65535) {
  usage(
    `--target, --secret, --socket, --key-file, and --port are required, and a` +
      ` holder binary must be available for ${process.platform}-${process.arch}` +
      " (via --holder-command, EVE_IDFON_HOLDER, or a platform package)"
  );
}
if (!existsSync(holderCommand)) {
  usage(`holder binary not found at ${holderCommand}` +
    " — pass --holder-command or install the eve-idfon platform package for this system");
}
if (!Number.isInteger(liveTtlSecs) || liveTtlSecs < 1) usage("--live-ttl-secs must be a positive integer");
const targetUrl = new URL(target);
if (!["localhost", "127.0.0.1", "[::1]", "::1"].includes(targetUrl.hostname)) {
  usage("--target must point to the local Eve HTTP server");
}

function usage(error) {
  if (error) console.error(`eve-idfon managed: ${error}`);
  console.error("usage: managed.mjs [--holder-command PATH] --target URL --secret VALUE --socket PATH --key-file FILE --port PORT [--blob-dir PATH] [--allow PEER_ID]...");
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
      console.error(`[eve-idfon] holder exited (${code ?? "signal"})`);
      void cleanup(code || 1);
    }
  });
} catch (error) {
  console.error(`[eve-idfon] managed startup failed: ${error.message}`);
  await cleanup(1);
}
