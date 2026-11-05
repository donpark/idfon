// rcan delegation tokens (wire format v2) for relay grants.
//
// Mirrors `crates/idfon-core::issue_relay_grant` and is pinned by the Rust
// `relay_grant_golden_vector` test plus `test.mjs` here: both sides must
// produce and accept the same bytes. Wire layout (see n0-computer/rcan):
//
//   token    = 0x02 | body | signature(64)      base32, lowercase, no padding
//   body     = issuer(32) | audience(32) | varint(origin) [| root(32)]
//              | varint(expires: 0=never, 1=at) [| varint(epoch)]
//              | varint(capability_len) | capability
//   signature= ed25519 over "rcan-2-delegation" | body
//
// The capability is postcard-encoded (`RelayGrant { relay, ticket_id }`).
// The rcan dependency is pinned to an unpublished rev in idfon-core, so this
// port is deliberately small and explicit rather than a JS reimplementation of
// the whole crate.

import crypto from "node:crypto";

const DST = Buffer.from("rcan-2-delegation", "utf8");
const VERSION = 0x02;
const BASE32 = "abcdefghijklmnopqrstuvwxyz234567";

export function base32Encode(bytes) {
  let acc = 0;
  let bits = 0;
  let out = "";
  for (const byte of bytes) {
    acc = (acc << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(acc >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(acc << (5 - bits)) & 31];
  return out;
}

export function base32Decode(text) {
  let acc = 0;
  let bits = 0;
  const out = [];
  for (const char of text.toLowerCase()) {
    const index = BASE32.indexOf(char);
    if (index < 0) throw new Error(`invalid base32 character ${JSON.stringify(char)}`);
    acc = (acc << 5) | index;
    bits += 5;
    if (bits >= 8) {
      out.push((acc >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

// postcard's unsigned varint (LEB128, minimal encoding).
function varint(value) {
  const out = [];
  let remaining = value;
  do {
    let byte = remaining % 128;
    remaining = Math.floor(remaining / 128);
    if (remaining > 0) byte |= 0x80;
    out.push(byte);
  } while (remaining > 0);
  return Buffer.from(out);
}

function readVarint(buf, offset) {
  let value = 0;
  let scale = 1;
  let index = offset;
  let byte;
  do {
    byte = buf[index++];
    if (byte === undefined) throw new Error("truncated varint");
    value += (byte & 0x7f) * scale;
    scale *= 128;
  } while (byte & 0x80);
  return [value, index];
}

function encodeRelayGrant({ relay, ticketId }) {
  const parts = [];
  if (relay == null) {
    parts.push(Buffer.from([0]));
  } else {
    const bytes = Buffer.from(relay, "utf8");
    parts.push(Buffer.from([1]), varint(bytes.length), bytes);
  }
  const id = Buffer.from(ticketId, "utf8");
  parts.push(varint(id.length), id);
  return Buffer.concat(parts);
}

function decodeRelayGrantPayload(buf) {
  let index = 0;
  const tag = buf[index++];
  let relay = null;
  if (tag === 1) {
    const [length, next] = readVarint(buf, index);
    relay = buf.subarray(next, next + length).toString("utf8");
    index = next + length;
  } else if (tag !== 0) {
    throw new Error("malformed grant relay field");
  }
  const [length, next] = readVarint(buf, index);
  const ticketId = buf.subarray(next, next + length).toString("utf8");
  index = next + length;
  if (index !== buf.length) throw new Error("trailing grant bytes");
  return { relay, ticketId };
}

/** RFC 3339 or epoch seconds -> epoch seconds; null means "never". */
export function expiryEpoch(value) {
  if (value == null || value === "") return null;
  const asNumber = Number(value);
  if (Number.isFinite(asNumber) && String(value).trim() !== "") return Math.trunc(asNumber);
  const parsed = Date.parse(String(value));
  if (Number.isNaN(parsed)) throw new Error(`unparseable expiry ${JSON.stringify(value)}`);
  return Math.trunc(parsed / 1000);
}

function delegationBody({ issuerHex, audienceHex, relay, ticketId, expiresAt }) {
  const capability = encodeRelayGrant({ relay, ticketId });
  const expires =
    expiresAt == null ? varint(0) : Buffer.concat([varint(1), varint(expiresAt)]);
  return Buffer.concat([
    Buffer.from(issuerHex, "hex"),
    Buffer.from(audienceHex, "hex"),
    varint(0), // capability origin: Issuer (a `delegate` would be 1 + root key)
    expires,
    varint(capability.length),
    capability,
  ]);
}

/** Signs a relay grant and returns its base32 token. */
export function signRelayGrant(privateKey, { issuerHex, audienceHex, relay, ticketId, expiresAt }) {
  const body = delegationBody({ issuerHex, audienceHex, relay, ticketId, expiresAt });
  const signature = crypto.sign(null, Buffer.concat([DST, body]), privateKey);
  return base32Encode(Buffer.concat([Buffer.from([VERSION]), body, signature]));
}

/** Decodes and signature-checks a relay grant token. Throws when malformed. */
export function decodeRelayGrant(token) {
  const bytes = base32Decode(String(token).trim());
  if (bytes.length < 1 + 64 + 64) throw new Error("token too short");
  if (bytes[0] !== VERSION) throw new Error(`unsupported rcan version ${bytes[0]}`);
  const signature = bytes.subarray(bytes.length - 64);
  const body = bytes.subarray(1, bytes.length - 64);

  const issuerHex = body.subarray(0, 32).toString("hex");
  const audienceHex = body.subarray(32, 64).toString("hex");
  let index = 64;
  let value;
  [value, index] = readVarint(body, index);
  const origin = value;
  let rootHex = null;
  if (origin === 1) {
    rootHex = body.subarray(index, index + 32).toString("hex");
    index += 32;
  } else if (origin !== 0 && origin !== 2) {
    throw new Error("malformed capability origin");
  }
  [value, index] = readVarint(body, index);
  let expiresAt = null;
  if (value === 1) {
    [value, index] = readVarint(body, index);
    expiresAt = value;
  } else if (value !== 0) {
    throw new Error("malformed expiry");
  }
  let capabilityLength;
  [capabilityLength, index] = readVarint(body, index);
  const { relay, ticketId } = decodeRelayGrantPayload(
    body.subarray(index, index + capabilityLength),
  );

  const der = Buffer.concat([
    Buffer.from("302a300506032b6570032100", "hex"),
    Buffer.from(issuerHex, "hex"),
  ]);
  const publicKey = crypto.createPublicKey({ key: der, format: "der", type: "spki" });
  let signatureValid = false;
  try {
    signatureValid = crypto.verify(null, Buffer.concat([DST, body]), publicKey, signature);
  } catch {
    signatureValid = false;
  }
  return { issuerHex, audienceHex, origin, rootHex, expiresAt, relay, ticketId, signatureValid };
}
