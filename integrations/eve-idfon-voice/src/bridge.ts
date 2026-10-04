// Channel helpers for the TS voice tools: blob upload (reply audio) and an
// agent→agent send that waits for the reply (the wrapping relay).

import idfonExtension from "eve-idfon";

export const bridgeUrl = (): string =>
  process.env.EVE_IDFON_BRIDGE_URL || idfonExtension.config?.bridgeUrl || "http://127.0.0.1:18766";

export const bridgeSecret = (): string =>
  process.env.EVE_IDFON_SECRET || idfonExtension.config?.secret || "m2-test-secret";

/** Upload reply audio and return its blob ticket. */
export async function putAudio(wav: Buffer): Promise<{ ticket: string; size_bytes: number }> {
  const response = await fetch(`${bridgeUrl()}/blob/put`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-idfon-channel-secret": bridgeSecret() },
    body: JSON.stringify({ bytes_base64: wav.toString("base64") }),
  });
  if (!response.ok) throw new Error(`idfon blob put returned HTTP ${response.status}`);
  return (await response.json()) as { ticket: string; size_bytes: number };
}

/** Push agent-produced PCM to the active call's return leg. */
export async function playAudio(peerId: string, pcm: Buffer): Promise<boolean> {
  const response = await fetch(`${bridgeUrl()}/live/audio`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-idfon-channel-secret": bridgeSecret() },
    body: JSON.stringify({ peer_id: peerId, pcm_base64: pcm.toString("base64") }),
  });
  if (!response.ok) throw new Error(`idfon live audio returned HTTP ${response.status}`);
  const result = (await response.json()) as { accepted?: boolean };
  return result.accepted ?? false;
}

/** Send text to a wrapped agent and wait for its reply (A2A relay). */
export async function sendAwait(
  peerId: string,
  endpointId: string,
  capabilityTicket: Record<string, unknown>,
  text: string,
  replyTo: string,
  timeoutMs = 60_000,
): Promise<string> {
  const response = await fetch(`${bridgeUrl()}/send`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-idfon-channel-secret": bridgeSecret() },
    body: JSON.stringify({
      peer_id: peerId,
      endpoint_id: endpointId,
      capability_ticket: capabilityTicket,
      text,
      a2a_depth: 1,
      await_reply: true,
      reply_to: replyTo,
      reply_timeout_ms: timeoutMs,
    }),
  });
  if (!response.ok) throw new Error(`idfon send returned HTTP ${response.status}`);
  const body = (await response.json()) as { reply?: { text?: string } };
  return body.reply?.text ?? "";
}
