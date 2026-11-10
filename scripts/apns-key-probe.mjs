#!/usr/bin/env node
// APNs key-scope probe (the 2026-11-10 investigation's first tool).
//
// Signs a provider JWT per key and POSTs to a garbage device token on BOTH
// APNs hosts. A garbage token never reaches a device; the error code reveals
// the key's environment scope:
//
//   400 BadDeviceToken            → key accepted in that environment
//   403 BadEnvironmentKeyInToken  → key rejected there (env-scoped key on the
//                                   wrong host — the real-world reason string,
//                                   matching what the edge's flip logic keys on)
//   403 InvalidProviderToken      → key id / team mismatch
//   429                           → rate limit; wait and retry
//
// A key accepted on both hosts is the universal (Sandbox & Production) key
// that TestFlight + dev-installed builds both need.
//
// Usage:
//   node scripts/apns-key-probe.mjs ~/.idfon/edge.apns.p8 A9R2SP5259 [TEAM] [TOPIC]
//   node scripts/apns-key-probe.mjs key.p8 KEYID RV27HPQNMF com.idfon.ios.voip
import crypto from "node:crypto";
import fs from "node:fs";

const [keyFile, kid, team = "RV27HPQNMF", topic = "com.idfon.ios.voip"] = process.argv.slice(2);
if (!keyFile || !kid) {
  console.error("usage: node scripts/apns-key-probe.mjs <key.p8> <key-id> [team] [topic]");
  process.exit(2);
}
const GARBAGE = "0".repeat(64);

const b64url = (buf) => Buffer.from(buf).toString("base64url");
const jwt = (() => {
  const key = fs.readFileSync(keyFile, "utf8");
  const header = b64url(JSON.stringify({ alg: "ES256", kid }));
  const claims = b64url(JSON.stringify({ iss: team, iat: Math.floor(Date.now() / 1000) }));
  const data = `${header}.${claims}`;
  const sig = crypto.sign("sha256", Buffer.from(data), { key, dsaEncoding: "ieee-p1363" });
  return `${data}.${b64url(sig)}`;
})();

for (const host of ["https://api.push.apple.com", "https://api.sandbox.push.apple.com"]) {
  try {
    const res = await fetch(`${host}/3/device/${GARBAGE}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": topic,
        "apns-push-type": "voip",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify({ call_uuid: "00000000-0000-0000-0000-000000000000" }),
    });
    console.log(`${host} -> ${res.status} ${await res.text()}`);
  } catch (e) {
    console.log(`${host} -> ERROR ${e.message}`);
  }
}
