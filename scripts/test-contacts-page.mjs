#!/usr/bin/env node
// The test-contacts page: every contact this machine serves, one tap away on
// the phone — no pairing launches, no `devicectl` console fishing.
//
//   node scripts/test-contacts-page.mjs --serve            # dynamic, port 8899
//   node scripts/test-contacts-page.mjs --serve --port 9000 --only llm,radio-tech
//   node scripts/test-contacts-page.mjs --out /tmp/contacts.html
//   node scripts/test-contacts-page.mjs --self-test
//
// Discovers the holder identities under ~/.idfon (each test agent/instance
// keeps one at <home>/holder.ticket) and renders one card per contact with a
// QR + `idfon://add/` link. Tapping the link opens the app's approval modal
// (rename, agent criteria, or deny).
//
// Credentials, per the contact's posture:
// - A public agent (live config opted in) gets a subject-less ticket minted
//   into the link — tap, approve, callable.
// - A protected agent gets a short **admission code** on its card instead.
//   The app's modal collects the code and redeems it at `POST /redeem` with
//   the device's own peer id; this script then does exactly what
//   `radio-admit.sh` does — allow-lists the sender and mints the
//   sender-bound ticket (`ticket --subject <peer>`) — and returns it.
//   Codes are one-shot and live only while `--serve` runs.
//
// That redemption is the whole pairing dance replaced: the holder's binding
// (`ticket.subject == sender.peer_id`) stays, the console round-trip goes.
//
// shortcut: the discovery is this machine's ~/.idfon only (the machine that
// runs the agents); widen to a shared registry if contacts ever live apart.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import qrcode from "qrcode-generator";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const HOME = process.env.EVE_VOICE_HOME_ROOT || path.join(os.homedir(), ".idfon");
const HOLDER = path.join(ROOT, "target/release/eve-idfon-voice");

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const flag = (name) => args.includes(`--${name}`);

// ---------- discovery

/** Every holder identity on this machine: the contacts we test with. */
async function discover(only) {
  const names = await readdir(HOME).catch(() => []);
  const contacts = [];
  for (const instance of names.sort()) {
    if (only.length && !only.includes(instance)) continue;
    const home = path.join(HOME, instance);
    const ticketFile = path.join(home, "holder.ticket");
    const keyFile = path.join(home, "holder.key");
    if (!existsSync(ticketFile) || !existsSync(keyFile)) continue;
    const contact = (await readFile(ticketFile, "utf8")).trim().split("\n")[0];
    // Live config (for `ticket --public` opt-ins); instance-named first.
    const live = [
      path.join(ROOT, "agents/radio/instances", instance, "live.json"),
      path.join(ROOT, "agents", instance, "live.json"),
    ].find((candidate) => existsSync(candidate));
    contacts.push({ instance, name: instance, home, keyFile, live, contact });
  }
  return contacts;
}

/** Mint a ticket the way radio-admit.sh does: key + optional live config. */
function mint(contact, ticketArgs) {
  const args = ["--key-file", contact.keyFile];
  if (contact.live) args.push("--live-config", contact.live);
  args.push("ticket", ...ticketArgs);
  const minted = spawnSync(HOLDER, args, { encoding: "utf8" });
  if (minted.status !== 0) return null;
  return minted.stdout.trim();
}

// ---------- envelopes

/** The `idfon://add/` payload: capability when public, auth code otherwise. */
function envelope(contact, { capability, auth }) {
  const payload = {
    contact: { ...JSON.parse(contact.contact), label: contact.name },
  };
  if (capability) payload.capability = JSON.parse(capability);
  if (auth) payload.auth = auth;
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
}

/** Admit `subject` to a protected contact: allow-list + sender-bound ticket. */
function admit(contact, subject) {
  const allow = path.join(contact.home, "allowed-peers");
  const listed = existsSync(allow) ? readFileSync(allow, "utf8").split("\n") : [];
  if (!listed.includes(subject)) writeFileSync(allow, `${listed.filter(Boolean).concat(subject).join("\n")}\n`);
  return mint(contact, ["--subject", subject]);
}

// ---------- codes (one-shot, per page load)

class Codes {
  #map = new Map();
  issue(instance) {
    const code = Math.random().toString(36).slice(2, 8).toUpperCase();
    this.#map.set(code, instance);
    return code;
  }
  redeem(raw) {
    const code = String(raw ?? "").trim().toUpperCase();
    const instance = this.#map.get(code);
    if (instance) this.#map.delete(code);
    return instance ?? null;
  }
}

// ---------- page

function lanAddress() {
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === "IPv4" && !entry.internal) return entry.address;
    }
  }
  return "127.0.0.1";
}

const escapeXml = (text) =>
  String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

function renderPage(rows) {
  const cards = rows
    .map(({ contact, link, posture, code }) => {
      const qr = qrcode(0, "L");
      qr.addData(link);
      qr.make();
      return `  <article>
    <h2>${escapeXml(contact.name)}</h2>
    <p class="posture">${escapeXml(posture)}</p>
    ${code ? `<p class="code">admission code <b>${escapeXml(code)}</b></p>` : ""}
    <p>${qr.createSvgTag({ cellSize: 3, margin: 4, scalable: true })}</p>
    <p><a href="${escapeXml(link)}">tap to add</a></p>
  </article>`;
    })
    .join("\n");
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Test contacts</title>
<style>
  body { font: 15px/1.45 -apple-system, sans-serif; margin: 1rem auto; max-width: 26rem; padding: 0 1rem; }
  article { border: 1px solid #ddd; border-radius: 10px; padding: 0.9rem 1rem; margin-bottom: 1rem; }
  h2 { margin: 0 0 0.25rem; font-size: 1.1rem; }
  .posture { margin: 0 0 0.5rem; color: #666; font-size: 0.85rem; }
  .code b { font-family: ui-monospace, monospace; font-size: 1.2rem; letter-spacing: 0.15em; }
  svg { width: 11rem; height: 11rem; }
</style>
</head>
<body>
<h1>Test contacts</h1>
${cards}
</body>
</html>
`;
}

/** One card row: public (ticket in the link) or protected (auth code). */
function cardRow(contact, codes, redeemURL) {
  const capability = mint(contact, ["--public"]);
  if (capability) {
    return {
      contact,
      link: `idfon://add/${envelope(contact, { capability })}`,
      posture: "public — tap to add and call",
      code: null,
    };
  }
  const code = codes.issue(contact.instance);
  return {
    contact,
    link: `idfon://add/${envelope(contact, {
      auth: {
        kind: "code",
        label: "Admission code",
        criteria: `${contact.name} gates admission on a sender-bound ticket. Enter the admission code shown on the test-contacts page.`,
        url: redeemURL,
      },
    })}`,
    posture: "protected — approval modal asks for the admission code",
    code,
  };
}

// ---------- self-test (no holder, no network)

function selfTest() {
  const contact = { instance: "x", name: "X", home: "/tmp", keyFile: "/none", live: null, contact: '{"id":"abc"}' };
  const link = envelope(contact, { auth: { kind: "code", label: "c", url: "http://n/redeem" } });
  const decoded = JSON.parse(Buffer.from(link, "base64url").toString("utf8"));
  if (decoded.contact.label !== "X" || decoded.auth.kind !== "code" || decoded.capability) {
    throw new Error("envelope shape wrong");
  }
  const codes = new Codes();
  const code = codes.issue("x");
  if (codes.redeem(code.toLowerCase()) !== "x") throw new Error("code redeem is case-insensitive");
  if (codes.redeem(code) !== null) throw new Error("codes are one-shot");
  console.log("ALL OK");
}

// ---------- main

if (flag("self-test")) {
  selfTest();
} else {
  const only = opt("only", "").split(",").filter(Boolean);
  const contacts = await discover(only);
  if (!contacts.length) {
    console.error(`test-contacts-page: no holder identities under ${HOME} — serve an agent first`);
    process.exit(1);
  }
  const port = Number(opt("port", "8899"));
  const codes = new Codes();
  const rowsFor = (redeemURL) => contacts.map((contact) => cardRow(contact, codes, redeemURL));

  const out = opt("out", "");
  if (out) {
    const rows = rowsFor(`http://${lanAddress()}:${port}/redeem`);
    writeFileSync(out, renderPage(rows));
    console.error(`test-contacts-page: ${rows.length} contact(s) -> ${out} (codes redeem only while --serve runs)`);
    console.log(`idfon:// page: file://${out}`);
  } else {
    const host = lanAddress();
    const server = http.createServer(async (request, response) => {
      if (request.method === "GET" && request.url === "/") {
        // Fresh page, fresh codes: every reload re-arms the one-shot codes.
        response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        response.end(renderPage(rowsFor(`http://${host}:${port}/redeem`)));
      } else if (request.method === "POST" && request.url === "/redeem") {
        let body = "";
        for await (const chunk of request) body += chunk;
        let reply, status;
        try {
          const { code, subject } = JSON.parse(body);
          const instance = codes.redeem(code);
          const contact = contacts.find((candidate) => candidate.instance === instance);
          const ticket = contact && subject ? admit(contact, subject) : null;
          console.error(
            `test-contacts-page: redeem code=${JSON.stringify(code)} instance=${instance ?? "?"} ` +
              `subject=${subject ? String(subject).slice(0, 12) : "missing"} -> ${ticket ? "ticket" : "denied"}`
          );
          [status, reply] = ticket
            ? [200, { ticket }]
            : [403, { error: "unknown code or subject" }];
        } catch {
          console.error(`test-contacts-page: redeem bad request: ${body.slice(0, 200)}`);
          [status, reply] = [400, { error: "bad request" }];
        }
        response.writeHead(status, { "content-type": "application/json" });
        response.end(JSON.stringify(reply));
      } else {
        response.writeHead(404).end();
      }
    });
    server.listen(port, () => {
      console.error(`test-contacts-page: ${contacts.length} contact(s) on http://${host}:${port}/`);
      for (const contact of contacts) console.error(`  - ${contact.instance}${contact.live ? "" : " (protected)"}`);
      console.log(`http://${host}:${port}/`);
    });
  }
}
