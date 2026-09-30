# Plan: CallMachine — one testable call state machine

Status: planned, not started. Reach for this when call/signaling trouble recurs
(it will — every bug in the 2026-09-19 session was found by device forensics
because none of this is testable today).

## Why

Call logic today lives in hand-ported state machines (`LiveCall`, `VideoCall`
in `mac/Sources/Idfon/Calls.swift` and `ios/Idfon/{LiveCall,VideoCall}.swift`)
that are singletons reaching into singletons: `DaemonClient` (live unix
socket), `AudioPusher`/`AudioMeter`/`CameraPusher` (AVFoundation), media FFI,
`UserDefaults`, `ChatStore` routing. Decisions and effects are interleaved at
every `await`, so nothing can run without a real daemon + mic + phone. The
same machine exists twice (mac/iOS) with manual parity, which is how the
platforms drift.

Bugs this design produced on 2026-09-19 alone: `installTap` SIGABRT from
unserialized engine mutations across three threads; invites consumed silently
as "return legs" by stale `.calling`/`.inCall` state; fire-once invite
delivery (`retries` defaulting to 0); `microphone unavailable` from a
second concurrent `start()` getting an immediate `running=false`;
`recoverStaleCall` vs stale-invite-filter interactions.

## Product model (decided 2026-09-19)

One unified call. All calls can be audio, video, or both; only one stream
needs to be enabled to start; once in-call, either stream can be toggled on or
off. Do not model calls as separate audio-call vs video-call machines. This
merge is half of the payoff: merging `LiveCall`+`VideoCall` into one
`CallMachine` is only safe to attempt with tests underneath.

## Design

Classic reducer split — decisions separated from effects:

```
enum CallInput {                 // everything that can happen to a call
  case inviteReceived(peer: PeerID, ticket: Ticket, media: MediaKind, at: Date)
  case returnLeg(peer: PeerID, ticket: Ticket)
  case callStopped(peer: PeerID)
  case publishReady(ticket: Ticket)        // media_live_start returned
  case publishFailed(reason: String)
  case subscribeFailed(reason: String)
  case remoteFrameArrived
  case toggleAudio(Bool), toggleVideo(Bool)
  case hangUpRequested
  case transportFailed(operation: OpID)
  case captureFailed(reason: String)       // mic/camera unavailable
}

enum CallEffect {                // everything the machine asks the world to do
  case sendEnvelope(peer: PeerID, text: String, retries: Int)
  case startCapture(.audio), stopCapture(.audio)
  case startCapture(.video), stopCapture(.video)
  case startPublish(audio: Bool, video: Bool)
  case subscribe(ticket: Ticket)
  case startRegistrySession(peer: PeerID, kind: String)
  case scheduleRecoverStaleCall(peer: PeerID)
  case presentIncoming, dismissCallUI      // UI hints; UI still observes state
}

struct CallState {
  phase: idle | incoming | calling | inCall | ended
  peer: PeerID?
  // per-stream availability + enabled flags (unified model)
  audioAvailable, videoAvailable, audioEnabled, videoEnabled: Bool
  publishedTicket: Ticket?
  lastError: String?
}

func reduce(_ state: CallState, _ input: CallInput, now: Date) -> (CallState, [CallEffect])
```

Rules that make it testable:
- `reduce` is pure: no singletons, no FFI, no clock reads (time is a
  parameter, so stale-invite/replay windows are test cases), no dispatching.
- Every decision that exists in today's code becomes a transition rule:
  duplicate/replayed invite superseding, return-leg vs fresh-invite
  discrimination, `activePeer == peerID` guards, staleness windows,
  publish-in-flight vs hung-up races, generation semantics (modeled as
  "effects superseded by later inputs").
- The runtime is the only place with side effects. It executes `[CallEffect]`
  and converts observations (FFI returns, capture failures, daemon events)
  back into `CallInput`s. Each platform keeps its existing concrete effects
  (`AudioPusher`/`AudioMeter`, `CameraPusher`, `DaemonClient.sendText`,
  media FFI) — those already got their thread-safety fixes and don't change.
- Staleness policy lives in the machine: "replayed invite older than 60s" and
  "replayed call_stopped older than 60s" become `at`-parameterized rules,
  testable by construction instead of `isStaleInvite` glimpsed in device logs.

## Platform layout

- `native/` already carries the signaling truth (`native/src/core.ts`) — the
  reducer's transition table is a Swift port of that plus the fixes since.
- mac: `mac/Sources/Idfon/CallMachine.swift` (reducer) +
  `CallRuntime.swift` (effects). `Calls.swift` shrinks to UI observation and
  the effect interpreters it already owns.
- iOS: same two files under `ios/Idfon/`. `LiveCall`/`VideoCall` are deleted
  once the unified machine covers both flows; `ChatStore` keeps its event
  routing but hands parsed inputs to `CallRuntime`.
- The daemon contract does not change: same envelopes, same registry entries,
  same FFI. This is a client-side restructure only.

## Test suite (the point of the exercise)

Scenario tests, pure `reduce` calls — microseconds, no daemon/mic/device.
Initial set taken directly from this week's incidents:

1. invite → ring → answer → return leg → in-call → stop → idle.
2. duplicate invite while `.incoming` (same peer) supersedes the ticket.
3. invite from a different peer while `.incoming` is ignored (no steal).
4. invite while `.calling`/`.inCall` (same peer) is a return leg, not a ring
   — and a stale-state recovery path exists so this can't swallow a ring.
5. replayed invite older than the staleness window → no ring.
6. hung up while publish in flight → stop effects emitted, no orphan publish.
7. publish failed → peer notified (`call_stopped`/stop envelope), UI shows
   error, machine ends.
8. toggle audio on a video-only dial → capture-start effect + gate effect.
9. toggle video on an audio-only call → same, per the unified model.
10. mac↔iOS parity: run the same scenario list through both runtimes'
    input-shaping layers (integration tests with a scripted transport, still
    no live network).

## Rollout order

1. mac `CallMachine` + reducer tests for scenarios 1–7 (today's crash
   history lives here). `VideoCall`/`LiveCall` delegate to it behind the
   existing API so UI code is untouched at first.
2. Fold unified-call semantics into the machine (single phase machine,
   per-stream toggles) and move mac UI over. Delete mac `LiveCall`
   audio-only paths that the machine now covers.
3. Port iOS to the same machine (it shares almost all logic; capture and
   session activation differ only in interpreter code).
4. Only after both platforms run the same machine: revisit signaling
   ergonomics (e.g. replace bare `call_stopped` texts with a versioned
   control envelope) — deliberately deferred, it's protocol churn.

## Non-goals / out of scope

- No daemon/protocol changes (envelope format unchanged).
- No capture rewrite — `AudioPusher`/`AudioMeter` thread fixes from
  2026-09-19 stay as-is; the machine only *calls* them via effects.
- No push-notification/background-delivery work (separate problem: an
  unreachable peer still can't be called; retries mitigate within the
  reconnect window only).
