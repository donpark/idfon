#!/usr/bin/env node
// Relay access auth service for a self-hosted iroh relay (docs/relay-auth.md).
//
// The relay's `access.http.url` callout hits POST /check with X-Iroh-Endpoint-Id
// (iroh-relay >= 1.4; older relays send the deprecated X-Iroh-NodeId);
// we answer "true" iff that endpoint id holds a live admission. Two kinds of
// stateful, random, endpoint-bound tokens sit in front of that:
//
//   owner      an identity homed on this relay ("claiming" it). Bootstraps by
//              signing a challenge with its identity key (one of
//              IDFON_RELAY_ISSUERS); may admit/revoke callers of that identity.
//   non-owner  a caller admitted by a signed, caller-bound grant (the idfon
//              CapabilityTicket `relay.use`, minted by an owner). Keeps its own
//              lease alive by refreshing; the grant is bootstrap/recovery only.
//
// Trust boundaries (all fail closed):
//   POST /check            bearer IDFON_RELAY_AUTH_TOKEN (the relay's callout)
//   POST /owner/challenge  open (returns a single-use nonce)
//   POST /owner/enroll     proof: ed25519 signature over the nonce by an
//                          issuer key in IDFON_RELAY_ISSUERS
//   /owner/* (the rest)    bearer owner token (or IDFON_RELAY_ADMIN_TOKEN)
//   POST /enroll           proof: verifiable grant (issuer ∈ issuers, subject-
//                          bound, unexpired, ticket not revoked)
//   POST /refresh          bearer non-owner token, bound to its endpoint id
//
// Tokens are `<id>.<secret>`; only sha256(secret) is stored. Revoking an entry
// or a ticket_id cascades to every token derived from it.
//
// Node >= 20, zero dependencies. TLS via IDFON_RELAY_AUTH_TLS_{CERT,KEY}.

import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import pathModule from "node:path";
import { pathToFileURL } from "node:url";

const OWNER_PROOF_PREFIX = "idfon-relay-owner/1";
const NONCE_TTL_MS = 5 * 60 * 1000;
const MAX_BODY = 64 * 1024;

export function loadConfig(env = process.env) {
  const issuers = new Set(
    (env.IDFON_RELAY_ISSUERS ?? "")
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter((s) => /^[0-9a-f]{64}$/.test(s)),
  );
  return {
    issuers,
    relayBearer: env.IDFON_RELAY_AUTH_TOKEN ?? "",
    adminBearer: env.IDFON_RELAY_ADMIN_TOKEN ?? "",
    dataPath: env.IDFON_RELAY_AUTH_DATA ?? "/data/state.json",
    // Lease = how long an admission stays live without a refresh/upsert.
    callerLeaseMs: days(env.IDFON_RELAY_LEASE_DAYS ?? "7"),
    ownerLeaseMs: days(env.IDFON_RELAY_OWNER_ENTRY_DAYS ?? "30"),
    // Token lifetimes; refresh at half-life is the client's job.
    callerTokenMs: days(env.IDFON_RELAY_CALLER_TTL_DAYS ?? "7"),
    ownerTokenMs: hours(env.IDFON_RELAY_OWNER_TTL_HOURS ?? "12"),
    httpPort: Number(env.IDFON_RELAY_AUTH_PORT ?? "9090"),
    httpsPort: Number(env.IDFON_RELAY_AUTH_TLS_PORT ?? "9443"),
    tlsCert: env.IDFON_RELAY_AUTH_TLS_CERT ?? "",
    tlsKey: env.IDFON_RELAY_AUTH_TLS_KEY ?? "",
  };
}

const days = (v) => Math.round(Number(v) * 24 * 60 * 60 * 1000);
const hours = (v) => Math.round(Number(v) * 60 * 60 * 1000);

// --- canonical grant bytes (mirrors idfon-core `ticket_unsigned`) -----------
// serde_json::Value maps are BTreeMaps: keys serialize ALPHABETICALLY, and
// absent optionals (path_scope / voice / relay) are omitted. Pinned by the
// golden vector in crates/idfon-core and test.mjs here.
export function canonicalGrantBytes(g) {
  const o = {
    capabilities: g.capabilities ?? [],
    conversation: g.conversation ?? null,
    expires_at: g.expires_at ?? null,
    issuer: String(g.issuer ?? "").toLowerCase(),
    subject: g.subject ?? null,
    ticket_id: g.ticket_id,
  };
  if (g.path_scope != null) o.path_scope = g.path_scope;
  if (g.relay != null) o.relay = g.relay;
  if (g.voice != null) o.voice = g.voice;
  const sorted = {};
  for (const k of Object.keys(o).sort()) sorted[k] = o[k];
  return Buffer.from(JSON.stringify(sorted), "utf8");
}

export function verifyEd25519(pubHex, message, sigHex) {
  if (!/^[0-9a-f]{64}$/i.test(pubHex) || !/^[0-9a-f]{128}$/i.test(sigHex)) {
    return false;
  }
  try {
    const der = Buffer.concat([
      Buffer.from("302a300506032b6570032100", "hex"),
      Buffer.from(pubHex, "hex"),
    ]);
    const key = crypto.createPublicKey({ key: der, format: "der", type: "spki" });
    return crypto.verify(null, message, key, Buffer.from(sigHex, "hex"));
  } catch {
    return false;
  }
}

// --- expiry ----------------------------------------------------------------
// Mirrors idfon_core::expiry_passed: epoch seconds or RFC 3339; unparseable
// counts as expired (fail closed).
export function expiryPassed(expiresAt, nowMs = Date.now()) {
  if (expiresAt == null) return true;
  const seconds = Number(expiresAt);
  if (Number.isFinite(seconds) && String(expiresAt).trim() !== "") {
    return seconds * 1000 <= nowMs;
  }
  const parsed = Date.parse(String(expiresAt));
  return Number.isNaN(parsed) || parsed <= nowMs;
}

const normalizeEndpoint = (v) => String(v ?? "").trim().toLowerCase();
const validEndpoint = (v) => /^[0-9a-f]{64}$/.test(normalizeEndpoint(v));

// --- state -----------------------------------------------------------------
function emptyState() {
  return { entries: {}, tokens: {}, revoked_tickets: [], challenges: {} };
}

export function loadState(path) {
  try {
    return { ...emptyState(), ...JSON.parse(fs.readFileSync(path, "utf8")) };
  } catch {
    return emptyState();
  }
}

function saveState(path, state) {
  const tmp = `${path}.tmp`;
  fs.mkdirSync(pathModule.dirname(path), { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, path);
}

// --- tokens ----------------------------------------------------------------
function issueToken(state, endpointId, role, identity) {
  const id = crypto.randomBytes(8).toString("hex");
  const secret = crypto.randomBytes(32).toString("hex");
  const ttl = role === "owner" ? state.config.ownerTokenMs : state.config.callerTokenMs;
  state.tokens[id] = {
    hash: sha256(secret),
    endpoint: endpointId,
    role,
    identity: identity ?? null,
    expires: Date.now() + ttl,
  };
  return { token: `${id}.${secret}`, expires: state.tokens[id].expires };
}

function consumeToken(state, presented, role) {
  const [id, secret] = String(presented ?? "").split(".");
  const row = state.tokens[id];
  if (!row || !secret) return null;
  const a = Buffer.from(row.hash, "hex");
  const b = Buffer.from(sha256(secret), "hex");
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  if (row.role !== role || row.expires <= Date.now()) return null;
  return { id, row };
}

const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");

function dropTokens(state, pred) {
  for (const [id, row] of Object.entries(state.tokens)) {
    if (pred(row)) delete state.tokens[id];
  }
}

// --- grant (bootstrap credential) -----------------------------------------
export function verifyGrant(state, grant) {
  if (!grant || typeof grant !== "object") return "malformed grant";
  const subject = normalizeEndpoint(grant.subject);
  if (!validEndpoint(subject)) return "grant subject is not an endpoint id";
  if (!state.config.issuers.has(String(grant.issuer ?? "").toLowerCase())) {
    return "grant issuer is not a trusted owner of this relay";
  }
  if (!Array.isArray(grant.capabilities) || !grant.capabilities.includes("relay.use")) {
    return "grant lacks the relay.use capability";
  }
  if (expiryPassed(grant.expires_at)) return "grant expired";
  if (state.revoked_tickets.includes(grant.ticket_id)) return "grant revoked";
  if (!verifyEd25519(grant.issuer, canonicalGrantBytes(grant), grant.signature)) {
    return "grant signature invalid";
  }
  return null;
}

// --- admission -------------------------------------------------------------
function admitted(state, endpointId) {
  const entry = state.entries[normalizeEndpoint(endpointId)];
  return Boolean(entry && entry.lease_expires > Date.now());
}

// --- HTTP ------------------------------------------------------------------
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks)) : {});
      } catch {
        reject(new Error("invalid JSON"));
      }
    });
    req.on("error", reject);
  });
}

const bearer = (req) => {
  const value = req.headers.authorization ?? "";
  return value.toLowerCase().startsWith("bearer ") ? value.slice(7).trim() : "";
};

export function createApp(config) {
  const state = { ...loadState(config.dataPath), config };

  const persist = () => saveState(config.dataPath, state);

  return async function handle(req, res) {
    const url = new URL(req.url, "http://localhost");
    const route = `${req.method} ${url.pathname}`;
    const send = (code, body) => {
      res.writeHead(code, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    const deny = (reason) => send(403, { error: reason ?? "denied" });

    try {
      if (route === "GET /healthz") return send(200, { ok: true });

      // Relay callout: the only answer the relay accepts is 200 "true".
      if (route === "POST /check") {
        if (!config.relayBearer || bearer(req) !== config.relayBearer) return deny("bad bearer");
        // Wire name is X-Iroh-Endpoint-Id (iroh-relay >= 1.4) -> lowercase
        // "x-iroh-endpoint-id". Deprecated X-Iroh-NodeId spellings still arrive
        // from older relays and are accepted as aliases; pinned against the
        // real relay in docs/relay-test-plan.md L2.
        const id = normalizeEndpoint(
          req.headers["x-iroh-endpoint-id"] ?? req.headers["x-iroh-nodeid"] ?? req.headers["x-iroh-node-id"],
        );
        const allowed = Boolean(id && admitted(state, id));
        console.log(`check ${id || "<no id>"} ${allowed ? "allow" : "deny"}`);
        if (allowed) {
          res.writeHead(200, { "content-type": "text/plain" });
          return res.end("true");
        }
        return deny("no live admission for this endpoint id");
      }

      if (req.method === "POST" && url.pathname === "/owner/challenge") {
        const body = await readBody(req);
        const identity = String(body.identity ?? "").toLowerCase();
        const endpoint = normalizeEndpoint(body.endpoint_id);
        if (!state.config.issuers.has(identity)) return deny("untrusted issuer");
        if (!validEndpoint(endpoint)) return deny("bad endpoint id");
        const nonce = crypto.randomBytes(16).toString("hex");
        state.challenges[nonce] = {
          identity,
          endpoint,
          purpose: String(body.purpose ?? "owner-enroll"),
          expires: Date.now() + NONCE_TTL_MS,
        };
        persist();
        return send(200, { nonce, expires: state.challenges[nonce].expires });
      }

      if (req.method === "POST" && url.pathname === "/owner/enroll") {
        const body = await readBody(req);
        const identity = String(body.identity ?? "").toLowerCase();
        const endpoint = normalizeEndpoint(body.endpoint_id);
        const challenge = state.challenges[body.nonce];
        delete state.challenges[body.nonce]; // single use, consumed either way
        if (!challenge || challenge.expires <= Date.now()) {
          persist();
          return deny("challenge missing or expired");
        }
        if (challenge.identity !== identity || challenge.endpoint !== endpoint) {
          persist();
          return deny("challenge does not match");
        }
        const proof = Buffer.from(
          `${OWNER_PROOF_PREFIX}|${identity}|${endpoint}|${body.nonce}`,
          "utf8",
        );
        if (!verifyEd25519(identity, proof, body.signature)) {
          persist();
          return deny("owner proof signature invalid");
        }
        state.entries[endpoint] = {
          ...(state.entries[endpoint] ?? {}),
          role: "owner",
          identity,
          lease_expires: Date.now() + config.ownerLeaseMs,
          updated: Date.now(),
        };
        const token = issueToken(state, endpoint, "owner", identity);
        persist();
        return send(200, { ...token, endpoint_id: endpoint });
      }

      // Caller bootstrap: the signed grant is checked once; the relay then
      // issues its own non-owner token and the grant goes back in the drawer.
      if (req.method === "POST" && url.pathname === "/enroll") {
        const body = await readBody(req);
        const problem = verifyGrant(state, body.grant);
        if (problem) return deny(problem);
        const endpoint = normalizeEndpoint(body.grant.subject);
        state.entries[endpoint] = {
          ...(state.entries[endpoint] ?? {}),
          role: "caller",
          identity: String(body.grant.issuer).toLowerCase(),
          account: body.account ?? null,
          label: body.label ?? null,
          ticket_id: body.grant.ticket_id ?? null,
          lease_expires: Date.now() + config.callerLeaseMs,
          updated: Date.now(),
        };
        const token = issueToken(state, endpoint, "non-owner", null);
        persist();
        return send(200, { ...token, endpoint_id: endpoint });
      }

      if (req.method === "POST" && url.pathname === "/refresh") {
        const auth = consumeToken(state, bearer(req), "non-owner");
        if (!auth) return deny("non-owner token required");
        const entry = state.entries[auth.row.endpoint];
        if (!entry) return deny("entry gone; re-enroll with the grant");
        entry.lease_expires = Date.now() + config.callerLeaseMs;
        entry.updated = Date.now();
        const token = issueToken(state, auth.row.endpoint, "non-owner", null);
        delete state.tokens[auth.id]; // rotate
        persist();
        return send(200, { ...token, endpoint_id: auth.row.endpoint });
      }

      // Everything below is owner/admin scoped.
      const presented = bearer(req);
      const asAdmin = Boolean(config.adminBearer) && presented === config.adminBearer;
      let owner = null;
      if (!asAdmin) {
        const auth = consumeToken(state, presented, "owner");
        if (!auth) return deny("owner token required");
        owner = auth.row.identity;
      }

      if (req.method === "POST" && url.pathname === "/owner/entries") {
        const body = await readBody(req);
        const endpoint = normalizeEndpoint(body.endpoint_id);
        if (!validEndpoint(endpoint)) return deny("bad endpoint id");
        const existing = state.entries[endpoint];
        if (!asAdmin && existing?.identity && existing.identity !== owner) {
          return deny("entry belongs to another identity");
        }
        let ticketId = body.ticket_id ?? null;
        if (body.grant) {
          const problem = verifyGrant(state, body.grant);
          if (problem) return deny(problem);
          if (normalizeEndpoint(body.grant.subject) !== endpoint) {
            return deny("grant subject does not match endpoint id");
          }
          ticketId = body.grant.ticket_id ?? ticketId;
        }
        const leaseMs = body.lease_days ? days(Number(body.lease_days)) : config.callerLeaseMs;
        // Never SHORTEN a live lease: a re-admit with the default lease once
        // silently downgraded a 10-year infra entry to 1 day. To reset a lease,
        // revoke and re-admit.
        const leaseExpires = Math.max(existing?.lease_expires ?? 0, Date.now() + leaseMs);
        state.entries[endpoint] = {
          ...(state.entries[endpoint] ?? {}),
          role: "caller",
          identity: owner,
          account: body.account ?? null,
          label: body.label ?? null,
          ticket_id: ticketId,
          lease_expires: leaseExpires,
          updated: Date.now(),
        };
        persist();
        console.log(`entry ${existing ? "update" : "add"} ${endpoint} lease ${new Date(leaseExpires).toISOString()}${ticketId ? ` ticket ${ticketId}` : ""}`);
        return send(200, { endpoint_id: endpoint, lease_expires: state.entries[endpoint].lease_expires });
      }

      if (req.method === "GET" && url.pathname === "/owner/entries") {
        return send(200, {
          entries: Object.entries(state.entries)
            .filter(([, e]) => asAdmin || !e.identity || e.identity === owner)
            .map(([endpoint_id, e]) => ({
            endpoint_id,
            role: e.role ?? "caller",
            identity: e.identity ?? null,
            account: e.account ?? null,
            label: e.label ?? null,
            ticket_id: e.ticket_id ?? null,
            lease_expires: e.lease_expires ?? 0,
          })),
        });
      }

      if (req.method === "DELETE" && url.pathname.startsWith("/owner/entries/")) {
        const endpoint = normalizeEndpoint(url.pathname.slice("/owner/entries/".length));
        const existing = state.entries[endpoint];
        if (!asAdmin && existing?.identity && existing.identity !== owner) {
          return deny("entry belongs to another identity");
        }
        delete state.entries[endpoint];
        dropTokens(state, (row) => row.endpoint === endpoint);
        persist();
        console.log(`entry revoke ${endpoint}`);
        return send(200, { revoked: endpoint });
      }

      if (req.method === "POST" && url.pathname === "/owner/revoke-ticket") {
        const body = await readBody(req);
        const ticketId = String(body.ticket_id ?? "");
        if (!ticketId) return deny("ticket_id required");
        if (!state.revoked_tickets.includes(ticketId)) state.revoked_tickets.push(ticketId);
        console.log(`ticket revoke ${ticketId}`);
        for (const [endpoint, entry] of Object.entries(state.entries)) {
          if (entry.ticket_id === ticketId && (asAdmin || !entry.identity || entry.identity === owner)) {
            delete state.entries[endpoint];
            dropTokens(state, (row) => row.endpoint === endpoint);
          }
        }
        persist();
        return send(200, { revoked_ticket: ticketId });
      }

      return send(404, { error: "not found" });
    } catch (error) {
      console.error(`error ${route}: ${error?.message ?? error}`);
      return send(400, { error: String(error?.message ?? error) });
    }
  };
}

// --- main ------------------------------------------------------------------
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const config = loadConfig();
  if (config.issuers.size === 0) {
    console.error("IDFON_RELAY_ISSUERS must list at least one 64-hex owner key (fail closed)");
    process.exit(1);
  }
  if (!config.relayBearer) {
    console.error("IDFON_RELAY_AUTH_TOKEN must be set (the relay callout's bearer; fail closed)");
    process.exit(1);
  }
  const app = createApp(config);
  http.createServer((req, res) => app(req, res)).listen(config.httpPort, () => {
    console.log(`relay-auth http :${config.httpPort}`);
  });
  if (config.tlsCert && config.tlsKey) {
    const tls = {
      cert: fs.readFileSync(config.tlsCert),
      key: fs.readFileSync(config.tlsKey),
    };
    https.createServer(tls, (req, res) => app(req, res)).listen(config.httpsPort, () => {
      console.log(`relay-auth https :${config.httpsPort}`);
    });
  } else {
    console.log("relay-auth: no TLS configured; only the internal listener is up");
  }
}
