// Per-session outbox for client-facing envelopes emitted by tools
// (docs/voice-multimodal.md).
//
// Tools that affect the client (`speak`, `point`, `show`) emit here instead of
// returning an envelope for the model to echo. The channel drains the outbox
// into the reply at `message.completed`, so delivery never depends on model
// compliance and the order of effects is the order of tool calls. In-process,
// single-writer, bounded.

const MAX_ENVELOPES = 16;
const MAX_CHARS = 16_000;

const bySession = new Map<string, string[]>();

/** Queue one client-facing envelope for the session's current turn. */
export function emitEnvelope(sessionId: string, envelope: string): void {
  const list = bySession.get(sessionId) ?? [];
  list.push(envelope);
  while (list.length > MAX_ENVELOPES) list.shift();
  while (list.length > 1 && list.join("\n").length > MAX_CHARS) list.shift();
  bySession.set(sessionId, list);
}

/** Remove and return the session's queued envelopes (delivery or discard). */
export function drainEnvelopes(sessionId: string): string[] {
  const list = bySession.get(sessionId) ?? [];
  bySession.delete(sessionId);
  return list;
}
