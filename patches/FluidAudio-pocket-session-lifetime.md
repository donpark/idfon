# Upstream patch: PocketTtsSession producer-task lifetime

`patches/FluidAudio-pocket-session-lifetime.patch` — for
[FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)
(verified against 0.17.5). Suggested title:

> fix(PocketTTS): own the session from its generation task

## Symptom

The second `synthesize` call on a `PocketTtsManager` can hang **forever**
(0% CPU, no thread running or blocked). Any voice kind is affected —
catalog (`voice:`) and cloned (`voiceData:`) alike — and the calls can be
perfectly sequential; no concurrency is required. Whether a given call hangs
depends on whether the cooperative scheduler runs the session's producer task
before the caller's local `session` reference is released — a few microseconds
of timing. Logging the code path makes the bug disappear (heisenbug).

## Root cause

`PocketTtsSession.start()` created the generation task with a **weak** capture:

```swift
generationTask = Task { [weak self] in
    guard let self else { return }
    await self.generateLoop()
}
```

Nothing else strongly retains the session actor: `synthesizeStreamingStateful`
returns `session.frames` (the stream does not retain its producer), the
`onTermination` hook captures weakly too, and the local `session` goes out of
scope on return. If the task begins after that release, `guard let self`
fails and the task **silently exits** — leaving `frames` orphaned and
unfinished: the consumer awaits a stream that will never yield again.

## Fix

The producer task owns the session until `generateLoop` returns:

```swift
generationTask = Task {
    await self.generateLoop()
}
```

### Lifetime semantics (reviewed)

- For a task that **completes**, retaining its `Task` handle does not
  permanently retain the closure's captures: a finished `Task` releases them,
  so the session (and its models) deallocates normally once callers drop it.
- **Persistent sessions** (`PocketTtsManager.makeSession`) are caller-owned:
  the owner must `finish()` or `cancel()` before dropping the session. An
  abandoned session — one that is dropped while its producer still waits for
  text — now keeps its models loaded until then (before this patch it would
  either leak the same way once its task started, or silently orphan its
  stream when the task started late — the bug). The `start()` documentation
  states this contract. Whether an explicit `close()`/auto-cancel lifecycle
  for abandoned sessions is wanted is a separate design decision; this patch
  does not change the abandonment semantics beyond making retention
  deterministic.
- `cancel()` semantics are unchanged (`generationTask?.cancel();
  textContinuation.finish(); await generationTask?.value`).

An alternative fix would keep the one-shot path's session alive at the call
site by returning a caller-held handle that owns the session until `frames`
terminates. (Note: strongly capturing the session in the *existing*
`frameContinuation.onTermination` hook would form a cycle — it lives inside
the session — so that is not a safe variant.)

## Regression tests (in the patch)

Two tests added to `PocketTtsSessionTests.swift`, both **bounded by explicit
deadlines** so a recurrence fails the suite instead of hanging it, and both
opt-in (`XCTSkip` when the `pocket_state.mlmodelc` language pack is not in
the local cache — the same convention as `PocketTtsStateEngineTests`):

- `testConsecutiveOneShotSynthesesTerminate` — three back-to-back one-shot
  `synthesize` calls must each return audio within 30 s. This is the failing
  shape of the bug (the hang was on the 2nd call).
- `testCancelTerminatesFramesStream` — cancelling a session mid-utterance
  must terminate the frames stream within 10 s.

## Validation (macOS 26, `.aneState` placement, v4 `english_18m_refl` pack)

- Before: 12/12 runs hung on the 1st or 2nd back-to-back `synthesize`.
- After: 12/12 runs complete 3 back-to-back syntheses; a 10-voice
  clone+synthesize batch (13 calls) completes in one process.
- The user-side serialization workaround (a serial queue worker) does **not**
  help: the calls were already sequential. Per-call process isolation works
  but is not viable in an app.

## Note on the repro

`PocketTtsManager(defaultVoice:language:directory:placement: .aneState)` +
`initialize()`, then `synthesize(text:voiceData:)` twice in a row with any
saved cloned voice. Hang probability near 100% when warm (second call).
