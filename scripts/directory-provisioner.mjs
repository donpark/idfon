#!/usr/bin/env node
// Catalog provisioner for the `directory` agent.
//
// The directory agent is the only thing that talks to this process, and this
// process is the only thing that mints contact invites. That is the chokepoint:
// caller policy, the model roster, and an audit log all live here rather than
// in the agent prompt.
//
//   node scripts/directory-provisioner.mjs            # serve on 127.0.0.1:18777
//   node scripts/directory-provisioner.mjs --self-check
//
// Env:
//   DIRECTORY_ROSTER        roster JSON (default agents/directory/roster.json)
//   DIRECTORY_PORT          listen port (default 18777)
//   DIRECTORY_SECRET        shared secret (default m2-test-secret)
//   DIRECTORY_ALLOW_CALLERS comma-separated caller endpoint ids (empty = any)
//   EVE_IDFON_GPT           holder binary (default target/release/eve-idfon-gpt)
//   IDFON_HOME              holder home root (default ~/.idfon)
//   DIRECTORY_AUDIT         invite audit log (default agents/directory/invites.ndjson)

import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const expandHome = (p) => (p.startsWith("~") ? resolve(homedir(), p.slice(2)) : p);

export function loadRoster(path) {
  const raw = JSON.parse(readFileSync(path, "utf8"));
  const contacts = Array.isArray(raw) ? raw : raw.contacts;
  if (!Array.isArray(contacts) || contacts.length === 0) {
    throw new Error(`roster ${path} has no contacts`);
  }
  return contacts;
}

export function findEntry(roster, query) {
  const q = String(query ?? "").trim().toLowerCase();
  return roster.find(
    (e) => e.name.toLowerCase() === q || String(e.model).toLowerCase() === q,
  );
}

// Mint a subject-bound capability ticket for `peerId` against a running holder,
// and pair it with the holder's endpoint address (its contact ticket).
// Injectable `run`/`home` keep this unit-testable without the Rust binary.
export function mintInvite(entry, peerId, options = {}) {
  const idfonHome = options.idfonHome ?? expandHome(process.env.IDFON_HOME ?? "~/.idfon");
  const home = expandHome(entry.home ?? `${idfonHome}/${entry.instance}`);
  const run = options.run ?? ((args) => execFileSync(options.bin, args, { encoding: "utf8" }));
  const read = options.read ?? ((p) => readFileSync(p, "utf8"));

  const capabilityTicket = JSON.parse(run(["--key-file", `${home}/holder.key`, "ticket", "--subject", peerId]));
  const addrLine = read(`${home}/holder.ticket`).split("\n").find((l) => l.trim());
  if (!addrLine) throw new Error(`holder ${home}/holder.ticket is empty`);
  const endpointAddr = JSON.parse(addrLine);
  const endpointId = endpointAddr.id ?? endpointAddr.endpoint_id;
  if (!endpointId) throw new Error("holder ticket has no endpoint id");

  // Invite lifetime, independent of the long-lived capability ticket: bounds
  // replay of the envelope without expiring the contact's send credential.
  const ttlSecs = options.ttlSecs ?? Number(process.env.DIRECTORY_INVITE_TTL_SECS ?? 3600);
  const expiresAt = Math.floor(Date.now() / 1000) + ttlSecs;
  const envelope = [
    "IDFON-INVITE/1",
    `name=${entry.name.replace(/[\r\n]/g, " ")}`,
    `model=${entry.model}`,
    `expires_at=${expiresAt}`,
    `contact=${JSON.stringify(endpointAddr)}`,
    `ticket=${JSON.stringify(capabilityTicket)}`,
  ].join("\n");
  return { name: entry.name, model: entry.model, endpoint_id: endpointId, endpoint_addr: endpointAddr, capability_ticket: capabilityTicket, expires_at: expiresAt, envelope };
}

// Admit `peerId` to the holder's live allow-file so the invite it just got is
// accepted without restarting the holder (see `--allow-file` in eve-idfon).
export function admit(entry, peerId, options = {}) {
  const idfonHome = options.idfonHome ?? expandHome(process.env.IDFON_HOME ?? "~/.idfon");
  const home = expandHome(entry.home ?? `${idfonHome}/${entry.instance}`);
  const file = `${home}/allowed-peers`;
  appendFileSync(file, `${peerId}\n`);
  return file;
}

function serve() {
  const rosterPath = resolve(repoRoot, process.env.DIRECTORY_ROSTER ?? "agents/directory/roster.json");
  const port = Number(process.env.DIRECTORY_PORT ?? 18777);
  const secret = process.env.DIRECTORY_SECRET ?? "m2-test-secret";
  const bin = process.env.EVE_IDFON_GPT ?? resolve(repoRoot, "target/release/eve-idfon-gpt");
  const auditPath = resolve(repoRoot, process.env.DIRECTORY_AUDIT ?? "agents/directory/invites.ndjson");
  const allowed = new Set(
    (process.env.DIRECTORY_ALLOW_CALLERS ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  );
  const roster = loadRoster(rosterPath);
  const idfonHome = expandHome(process.env.IDFON_HOME ?? "~/.idfon");

  const available = (e) => existsSync(expandHome(e.home ?? `${idfonHome}/${e.instance}`) + "/holder.ticket");

  const send = (res, code, body) => {
    res.writeHead(code, { "content-type": "application/json" });
    res.end(JSON.stringify(body));
  };

  const server = createServer((req, res) => {
    if (req.headers["x-idfon-provisioner-secret"] !== secret) {
      return send(res, 401, { error: "unauthorized" });
    }
    if (req.method === "GET" && req.url === "/catalog") {
      return send(res, 200, {
        contacts: roster.map((e) => ({ name: e.name, model: e.model, available: available(e) })),
      });
    }
    if (req.method !== "POST" || req.url !== "/invite") {
      return send(res, 404, { error: "not found" });
    }
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      let request;
      try {
        request = JSON.parse(body || "{}");
      } catch {
        return send(res, 400, { error: "invalid JSON" });
      }
      const { peer_id: peerId, model } = request;
      if (!peerId) return send(res, 400, { error: "peer_id is required" });
      if (allowed.size > 0 && !allowed.has(peerId)) {
        return send(res, 403, { error: "caller not allowed" });
      }
      const entry = findEntry(roster, model);
      if (!entry) return send(res, 404, { error: `no catalog entry for ${model}` });
      try {
        const invite = mintInvite(entry, peerId, { bin, idfonHome });
        const allowFile = admit(entry, peerId, { idfonHome });
        appendFileSync(
          auditPath,
          JSON.stringify({ at: new Date().toISOString(), peer_id: peerId, name: invite.name, model: invite.model, endpoint_id: invite.endpoint_id, allow_file: allowFile }) + "\n",
        );
        send(res, 200, invite);
      } catch (error) {
        send(res, 502, { error: String(error.message ?? error) });
      }
    });
  });
  server.listen(port, "127.0.0.1", () => {
    console.error(`[directory-provisioner] catalog on http://127.0.0.1:${port} (${roster.length} contacts)`);
  });
}

function selfCheck() {
  const home = mkdtempSync(join(tmpdir(), "dir-prov-"));
  writeFileSync(join(home, "holder.key"), "k");
  writeFileSync(join(home, "holder.ticket"), JSON.stringify({ id: "holder-ep", addrs: [] }) + "\n");
  const entry = { name: "Unit Model", model: "unit/model", home };
  const invite = mintInvite(entry, "caller-ep", {
    read: (p) => readFileSync(p, "utf8"),
    run: (args) => JSON.stringify({ type: "capability", subject: args[args.length - 1] }),
  });
  if (invite.endpoint_id !== "holder-ep") throw new Error("endpoint id mismatch");
  if (!invite.envelope.startsWith("IDFON-INVITE/1\n")) throw new Error("bad envelope");
  if (!invite.envelope.includes("model=unit/model")) throw new Error("missing model");
  if (!/expires_at=\d+/.test(invite.envelope)) throw new Error("missing invite expiry");
  if (!invite.envelope.includes("subject\":\"caller-ep")) throw new Error("ticket not subject-bound");
  admit(entry, "caller-ep");
  if (!readFileSync(join(home, "allowed-peers"), "utf8").includes("caller-ep")) {
    throw new Error("caller not admitted to allow-file");
  }
  console.log("PASS: roster -> subject-bound invite envelope + allow-file admit");
}

if (process.argv.includes("--self-check")) selfCheck();
else serve();
