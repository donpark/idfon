# Troubleshooting and known issues

Notes on real failure modes observed during testing, their root causes, and
the fixes. Kept so the same class of bug is easy to recognize next time.

## GUI sends rejected with `idempotency_key_conflict` (2026-08-30)

**Symptom.** Sending a chat message from one GUI instance to another was
silently not received. The GUI showed the message as failed (or nothing at
all); no `message.received` event ever appeared on the other side, and no new
operation was created in the daemon store.

**Diagnosis path.**

1. GUI trace logs (`/tmp/nufon-<pid>.log`, written by `native/src/iroh_ffi.zig`)
   showed the daemon's response to `message.send`:
   `{"ok":false,"error":{"code":"idempotency_key_conflict",...}}`.
2. The daemon store (`/tmp/nufon*/state.json`) contained operations from
   *previous* testing sessions with the same `(target, idempotency_key)` pair
   but a different request fingerprint.
3. The GUI (`native/src/core.ts`) built the idempotency key as
   `gui-${model.history.length}` — a value derived only from in-memory state
   that resets on every app restart. Every fresh session started keying sends
   `gui-0`, `gui-1`, ... again, colliding with operations persisted days
   earlier.

**Root cause.** The daemon deduplicates `message.send` on
`(target, idempotency_key)` and compares the request fingerprint when a pair
matches. That behavior is correct and intentional (safe retries, see
*Operations and retries* in the architecture plan). The bug was client-side:
the GUI reused keys across process restarts, so a brand-new message looked
like a replay of an old one and was rejected — or worse, would have been
answered with the *stale* operation's `delivered` status without being sent.

**Fix.** Send keys are now unique per message *and* per session:
`gui-${tickAt}-${history.length}`, where `tickAt` is the timestamp delivered
by the 1-second event-poll timer (`poll_events` msg). This survives restarts
and cannot collide across sessions. Note the Native SDK checker forbids
reading `Date.now()` inside `update` (updates must stay deterministic);
ambient time must arrive through the subscription tick instead.

**Lesson.** Idempotency keys derived from client-local state that resets
(history length, per-session counters) are not unique across restarts. Keys
must be unique per distinct send over the *daemon's* lifetime of stored
operations, not per GUI session.

**Testing note.** Testing two identities (Alice/Bob) on one computer is a
test-only setup: both app instances normally talk to the same default-profile
daemon unless each is launched with its own profile
(`native/run-profile.sh <name>` sets `NUFON_PROFILE`, giving each instance its
own socket and data directory under `/tmp/nufon-<name>/`). The bug above was
independent of that setup — it would bite identically between two machines —
but the shared-daemon setup made the stale operations from earlier sessions
visible in one `state.json`, which helped diagnosis.

## Related: stale daemon lock after a crash (2026-08-30)

A crashed daemon left `/tmp/nufon/state.lock` behind (its `Drop` never ran),
and every subsequent daemon start failed with
`data directory is already locked: ...`, which the GUI surfaced as
`daemon_unavailable`. Fixed in `DataLock::acquire`
(`crates/nufond/src/main.rs`): the lock file records the holder's PID, and a
new daemon now takes the lock over when that PID is dead. See the
`data_lock_recovers_stale_lock_from_dead_pid` test.
