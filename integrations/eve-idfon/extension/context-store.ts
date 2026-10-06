// Host-owned virtual context (docs/session-context.md).
//
// Each agent loop host owns its own context and only its agent edits it, so this
// is a single-writer store: keyed by durable session id, in-process, no merge or
// locking (Node's event loop serializes edits). Bounded; eviction is the host's
// own compaction, oldest key first.

const MAX_ENTRIES = 32;
const MAX_TOTAL_CHARS = 8_000;
const MAX_VALUE_CHARS = 2_000;

const bySession = new Map<string, Map<string, string>>();

function session(sessionId: string): Map<string, string> {
  let entries = bySession.get(sessionId);
  if (!entries) {
    entries = new Map();
    bySession.set(sessionId, entries);
  }
  return entries;
}

function totalChars(entries: Map<string, string>): number {
  let total = 0;
  for (const [key, value] of entries) total += key.length + value.length;
  return total;
}

/** A plain-object snapshot of the session's context entries. */
export function contextEntries(sessionId: string): Record<string, string> {
  return Object.fromEntries(session(sessionId));
}

/** Set one key (refreshes recency), clamping the value and evicting oldest. */
export function contextSet(sessionId: string, key: string, value: string): void {
  const entries = session(sessionId);
  const clamped = value.length > MAX_VALUE_CHARS ? value.slice(0, MAX_VALUE_CHARS) : value;
  entries.delete(key);
  entries.set(key, clamped);
  while (entries.size > MAX_ENTRIES || totalChars(entries) > MAX_TOTAL_CHARS) {
    const oldest = entries.keys().next().value;
    if (oldest === undefined) break;
    entries.delete(oldest);
  }
}

export function contextGet(sessionId: string, key: string): string | undefined {
  return session(sessionId).get(key);
}

export function contextDelete(sessionId: string, key: string): boolean {
  return session(sessionId).delete(key);
}

/** Drop the oldest entries until the store is at or below `keep` entries. */
export function contextCompact(sessionId: string, keep = MAX_ENTRIES / 2): number {
  const entries = session(sessionId);
  let dropped = 0;
  while (entries.size > Math.max(0, keep)) {
    const oldest = entries.keys().next().value;
    if (oldest === undefined) break;
    entries.delete(oldest);
    dropped += 1;
  }
  return dropped;
}

export function contextClear(sessionId: string): void {
  session(sessionId).clear();
}
