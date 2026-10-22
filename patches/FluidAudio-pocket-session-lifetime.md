# Upstream patch: PocketTtsSession producer-task lifetime

`patches/FluidAudio-pocket-session-lifetime.patch` — for
[FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)
(verified against 0.17.5). Suggested title:

> fix(PocketTTS): keep the session alive until its generation loop starts

## Symptom

The second `synthesize` call on a `PocketTtsManager` can hang **forever**
(0% CPU, no thread running or blocked). Any voice kind is affected —
catalog (`voice:`) and cloned (`voiceData:`) alike — and the calls can be
perfectly sequential; no concurrency is required. Whether a given call hangs
depends on whether the cooperative scheduler runs the session's producer task
before the caller's local `session` reference is released — a few microseconds
of timing. Logging the code path makes the bug disappear (heisenbug).

## Root cause

`PocketTtsSession.start()` creates the generation task with a **weak** capture:

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
fails, the task **silently exits**, and `frames` is never finished or fed —
the consumer awaits a stream that will never yield again. A lost wakeup.

## Fix

The producer task must own the session until `generateLoop` returns:

```swift
generationTask = Task {
    await self.generateLoop()
}
```

No leak: a finished `Task` releases its closure captures, so the session
deallocates normally once callers drop it (it takes the finished task with it).
`cancel()`'s `await generationTask?.value` semantics are unchanged.

Alternative fixes (if the maintainers prefer): have `synthesizeStreamingStateful`
keep the session alive until `frames` terminates (e.g. capture it in the
stream's `onTermination`), or return a handle that owns the session.

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
