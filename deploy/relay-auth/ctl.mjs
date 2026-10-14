#!/usr/bin/env node
// CLI for the relay-auth service (deploy/relay-auth/server.mjs): owner
// bootstrap, admitting/revoking endpoints, and the /check probe. This is the
// manual test/ops surface until the daemon does it automatically
// (docs/relay-auth.md §6).
//
//   node deploy/relay-auth/ctl.mjs enroll-owner --key-file ~/.idfon/identity-default.key \
//        --base https://relay.example.com:9443 [--endpoint <hex>]
//   node deploy/relay-auth/ctl.mjs mint-grant --key-file KEY --endpoint <hex> \
//        [--ticket <id>] [--expires <rfc3339|epoch>] [--relay <url>]   -> grant JSON
//   node deploy/relay-auth/ctl.mjs enroll-grant --grant <file> [--label L] -> non-owner token
//   node deploy/relay-auth/ctl.mjs refresh  --token NON_OWNER_TOKEN
//   node deploy/relay-auth/ctl.mjs admit    --token OWNER --endpoint <hex> [--label edge] [--lease-days 3650]
//   node deploy/relay-auth/ctl.mjs revoke   --token OWNER --endpoint <hex>
//   node deploy/relay-auth/ctl.mjs revoke-ticket --token OWNER --ticket <id>
//   node deploy/relay-auth/ctl.mjs entries  --token OWNER
//   node deploy/relay-auth/ctl.mjs check    --endpoint <hex> [--bearer RELAY_TOKEN]
//
// `enroll-owner` and `mint-grant` sign with the identity key (the hex seed
// that idfon stores in `identity-<id>.key`); the identity public id is derived
// from it. Tokens are short-lived — re-run to rotate.

import crypto from "node:crypto";
import fs from "node:fs";
import { canonicalGrantBytes } from "./server.mjs";

const args = process.argv.slice(2);
let command = null;
for (let i = 0; i < args.length; i += 1) {
  if (!args[i].startsWith("--")) {
    command = args[i];
    break;
  }
  i += 1; // every --flag takes a value; skip it
}
const opt = (name, fallback = null) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

function keypairFromSeedFile(file) {
  const seedHex = fs.readFileSync(file, "utf8").trim();
  if (!/^[0-9a-f]{64}$/i.test(seedHex)) throw new Error(`${file}: expected a 64-hex seed`);
  const der = Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"),
    Buffer.from(seedHex, "hex"),
  ]);
  const privateKey = crypto.createPrivateKey({ key: der, format: "der", type: "pkcs8" });
  const pubHex = Buffer.from(
    crypto.createPublicKey(privateKey).export({ format: "jwk" }).x,
    "base64url",
  ).toString("hex");
  return { pubHex, privateKey };
}

const sign = (key, message) =>
  crypto.sign(null, Buffer.isBuffer(message) ? message : Buffer.from(message, "utf8"), key).toString("hex");

async function call(base, route, { body, token, method } = {}) {
  const res = await fetch(`${base}${route}`, {
    method: method ?? (body === undefined ? "GET" : "POST"),
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (res.status !== 200) throw new Error(`${route} -> ${res.status} ${text}`);
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

const base = opt("base", "http://127.0.0.1:9090");

switch (command) {
  case "enroll-owner": {
    const key = keypairFromSeedFile(opt("key-file") ?? fail("--key-file required"));
    const endpoint = opt("endpoint", key.pubHex);
    const { nonce } = await call(base, "/owner/challenge", {
      body: { identity: key.pubHex, endpoint_id: endpoint },
    });
    const proof = `idfon-relay-owner/1|${key.pubHex}|${endpoint}|${nonce}`;
    const result = await call(base, "/owner/enroll", {
      body: { identity: key.pubHex, endpoint_id: endpoint, nonce, signature: sign(key.privateKey, proof) },
    });
    console.log(JSON.stringify(result, null, 2));
    break;
  }
  case "admit": {
    const result = await call(base, "/owner/entries", {
      token: opt("token") ?? fail("--token required"),
      body: {
        endpoint_id: opt("endpoint") ?? fail("--endpoint required"),
        label: opt("label"),
        account: opt("account"),
        ticket_id: opt("ticket"),
        lease_days: opt("lease-days") ? Number(opt("lease-days")) : undefined,
      },
    });
    console.log(JSON.stringify(result, null, 2));
    break;
  }
  case "mint-grant": {
    const key = keypairFromSeedFile(opt("key-file") ?? fail("--key-file required"));
    const grant = {
      issuer: key.pubHex,
      subject: opt("endpoint") ?? fail("--endpoint required (the subject endpoint id)"),
      capabilities: ["relay.use"],
      expires_at: opt("expires", "2030-01-01T00:00:00Z"),
      ticket_id: opt("ticket", `ticket-${Date.now()}`),
    };
    const relay = opt("relay");
    if (relay) grant.relay = relay;
    grant.signature = sign(key.privateKey, canonicalGrantBytes(grant));
    console.log(JSON.stringify(grant, null, 2));
    break;
  }
  case "enroll-grant": {
    const grant = JSON.parse(fs.readFileSync(opt("grant") ?? fail("--grant <file> required"), "utf8"));
    console.log(
      JSON.stringify(await call(base, "/enroll", { body: { grant, label: opt("label") } }), null, 2),
    );
    break;
  }
  case "refresh":
    console.log(
      JSON.stringify(
        await call(base, "/refresh", { method: "POST", token: opt("token") ?? fail("--token required") }),
        null,
        2,
      ),
    );
    break;
  case "revoke":
    console.log(
      JSON.stringify(
        await call(base, `/owner/entries/${opt("endpoint") ?? fail("--endpoint required")}`, {
          token: opt("token") ?? fail("--token required"),
          method: "DELETE",
        }),
        null,
        2,
      ),
    );
    break;
  case "revoke-ticket":
    console.log(
      JSON.stringify(
        await call(base, "/owner/revoke-ticket", {
          token: opt("token") ?? fail("--token required"),
          body: { ticket_id: opt("ticket") ?? fail("--ticket required") },
        }),
        null,
        2,
      ),
    );
    break;
  case "entries":
    console.log(
      JSON.stringify(await call(base, "/owner/entries", { token: opt("token") ?? fail("--token required") }), null, 2),
    );
    break;
  case "check": {
    const endpoint = opt("endpoint") ?? fail("--endpoint required");
    const res = await fetch(`${base}/check`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${opt("bearer", "")}`,
        "x-iroh-node-id": endpoint,
      },
    });
    console.log(`${res.status} ${await res.text()}`);
    break;
  }
  default:
    fail(
      "usage: ctl.mjs <enroll-owner|mint-grant|enroll-grant|refresh|admit|revoke|revoke-ticket|entries|check> --base URL ...",
    );
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
