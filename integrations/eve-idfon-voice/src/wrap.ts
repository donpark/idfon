// Wrapped-agent target: where a voice agent relays caller text.
//
// Config comes from `IDFON_VOICE_ENGINE.wrap` (peer_id, endpoint_id, ticket),
// so a voice agent that wraps a fixed agent needs no tool arguments:
//
//   { "stt": {...}, "tts": {...},
//     "wrap": { "peer_id": "<wrapped>", "endpoint_id": "<wrapped>",
//               "ticket": { ... agency-issued capability ticket ... } } }

import { sendAwait } from "./bridge";
import { engineConfig } from "./providers";

export interface WrapTarget {
  peerId: string;
  endpointId: string;
  ticket: Record<string, unknown>;
}

/** Resolve the wrapped target from config, with optional per-call overrides. */
export function wrapTarget(overrides: Partial<WrapTarget> = {}): WrapTarget {
  const wrap = engineConfig().wrap ?? {};
  const peerId = overrides.peerId ?? String(wrap.peer_id ?? "");
  const endpointId = overrides.endpointId ?? String(wrap.endpoint_id ?? "");
  const ticket = overrides.ticket ?? (wrap.ticket as Record<string, unknown> | undefined);
  if (!peerId || !endpointId || !ticket) {
    throw new Error(
      "wrapped target not configured: set IDFON_VOICE_ENGINE.wrap {peer_id,endpoint_id,ticket} or pass peer/endpoint/ticket",
    );
  }
  return { peerId, endpointId, ticket };
}

/** Send text to the wrapped agent and return its reply text. */
export async function forwardToWrapped(
  text: string,
  target: WrapTarget = wrapTarget(),
  timeoutMs?: number,
): Promise<string> {
  const replyTo = `wrap-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  return (
    await sendAwait(target.peerId, target.endpointId, target.ticket, text, replyTo, timeoutMs)
  ).trim();
}
