# Workspace and context: threads as offices

Why the chat is the unit of context, what may be global, and how something
moves from one thread to another. This is the model the app already leans on
(`docs/session-context.md`: the session log is the medium, never the model's
context); this page states it so new features stop re-deciding it.

## The picture

A thread is an **office**: one conversation with the people and agents in it,
holding everything that happened there. Offices **nest**:

```
workspace → thread → call → turn
```

Only people move between offices. Context does not follow them; it is carried
on purpose, or it does not exist in the new office.

## Rules

1. **One global: the root scope.** "Global" means "the outermost context".
   Anything that wants to be global is either a *default* (data at the root:
   relay config, default codec) or a *capability* (outside the tree entirely,
   below).
2. **Resolve by ownership, not by focus.** A call belongs to the thread that
   started it. Reading "the current call" from another thread must not find
   it. Structure decides; where the user is looking does not.
3. **Reads walk up, writes stay put.** Innermost scope wins, absence
   propagates outward. A root default cannot leak, because nothing overwrites
   it with instance data.
4. **Knowledge lives in the tree; capabilities do not.** A socket, the audio
   engine, the clock, permissions — handles outside. *Knowledge of them* —
   availability, permission, current state, limits, freshness — is data in the
   scope that owns that slice: device-wide at the root, per-call at the call,
   per-peer at the thread. Test: if it can be written as plain data, scoped and
   replayed, it belongs in the tree; if replaying it would open a socket, it is
   a capability.
5. **No control in the tree.** The context holds belief, not instructions. An
   actor (person, agent, capability) acts *given* that belief. Enforcement
   belongs to the authority — the audio session that refuses to open, the
   socket that will not bind — and the refusal becomes an observation.
6. **Every fact carries an owner and `as_of`.** Otherwise a reader cannot tell
   "playing" from "was playing". Mirrors go stale; stamp them.
7. **Knowledge flows down; context never flows sideways.** Inheritance is
   implicit. Sibling → sibling is an explicit carry (a reference, a ticket, a
   move), which is the consent and attribution stamp. Carry what cannot be
   derived; derive what the target scope can recompute (codec, route, contact)
   — carrying those is duplication that drifts.

## Where it is already true

- **Per-call quality record** (`media-adaptation.md` §C1/§C2): folded at
  hangup, filed under the peer it describes, shown by `/health-check` in that
  thread. It never rides the wire — it carries local addresses and RTT.
- **`/health-check`** is knowledge placed where the actor already is, not a new
  screen.
- **Media state** (`media_live_state`, `media_live_path`, `NetworkSignals`) is
  capability knowledge mirrored into the call scope for the bar; the media
  plane owns the truth and decides, the shell only displays.

## Where it is not (yet)

- `LiveCall`/`VideoCall` still mix the capability handle and its state in one
  singleton; the split is `call → thread scope` for state, a handle beside the
  tree for the engine.
- `media_health_last_report` is a process-global hand-off (read-and-clear).
  The per-thread file is the durable form; the global is just transport.
- Diag events are not tagged with a scope path yet, so cross-thread attribution
  of a log line depends on timestamps.

## Why non-determinism is fine

Actors are non-deterministic; interactions are not derivable from knowledge.
Determinism lives in *folding observations*: same observations in the same
order → same belief. So the context is replayable and testable with recorded
traces, and never pretends to predict what an actor will do next.
