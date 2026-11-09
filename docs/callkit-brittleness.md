# CallKit/PushKit brittleness and options

**Date:** 2026-11-09
**Scope:** Current iOS CallKit/PushKit call path, plus the two-phone call attempt
captured on 2026-11-09. This is a repository assessment, not an independent audit
of every Apple API or App Review rule.

## Executive summary

**Keep CallKit + PushKit for calls that must ring on a locked or suspended iPhone.**
It is the only option here that provides the native incoming-call surface and a
supported VoIP wake path. It is also a brittle chain: caller mode → media publish
→ invite queue → edge ring → APNs environment/token → PushKit callback → immediate
CallKit report → invite/media readiness → CallKit audio handoff. A failure at any
link can look to the user like “the phone did not ring.”

A key architectural risk is **control-plane work waits for media publish**:
`VideoCall.dialNow` obtains the live media ticket before it sends the start invite
and calls `PushWake.ring`. The wife's earlier attempts ended before any start send
was observed; their exact pre-send stage remains open. The later Gemini38 attempt
shows a different failure: publisher setup succeeded, but the queued messages were
not acknowledged before hang-up. Neither case is evidence of a CallKit delegate
failure. The ringback trace also found an audio-queue ordering race, now fixed in
the working tree but awaiting device verification.

Recommended order:

1. Add stage-level timing and a visible failure for native media-publish startup;
   enforce a timeout at the native boundary if it can block. Confirm the exact
   hang before changing the protocol.
2. For dependable ringing, decouple a call-attempt ID from the media ticket so the
   invite/ring can be reported while media setup proceeds. Preserve pending-answer,
   cancellation, deduplication, and generation checks.
3. Keep the in-app Bar as an explicit foreground-only mode. Do not promise that it
   wakes a locked phone.

## Evidence from the 2026-11-09 calls

The first two-phone attempt logs are in `/tmp/idfon-wife-{a,b}-{app,daemon}.log`;
the later Gemini38 attempt is detailed below.

- Both phones started classic audio/video dial attempts while active. The daemon
  logged `media.session.start`; local audio started, and camera capture was later
  toggled. The camera-toggle log still said `published=false`.
- Neither daemon log shows a call-start `message.send`; neither app log shows
  `idfon push: ring` or an incoming PushKit callback. The only call-control messages
  observed were stop envelopes, with `ticket=false`, when attempts ended.
- The absence of a start invite and ring request places this failure before the
  invite/PushKit/CallKit incoming path. The source path between local media-session
  setup and invite send calls `media_live_start_with_profile`, which calls
  `Live::from_env()` and binds another iroh endpoint before creating the live
  ticket. No `endpoint bound` marker or FFI return/error appears in the call
  window. The deeper native failure is **not yet proven**; new stage markers now
  separate endpoint setup, broadcast creation, ticket creation, and FFI return.
- On the caller phone, the diagnostic trace explicitly says `callMode=bar` and
  `outgoing presentation=Bar` for the wife contact. A read-only pull of
  `idfon.peerModes` also shows no entry for that peer, so the caller resolves to
  the `.bar` default. This mode intentionally suppresses PushKit and CallKit. The
  setting must be changed on the *caller’s* copy of the contact; changing the
  caller’s contact on the recipient's phone does not affect this gate.
- The caller phone's own PushKit registration retried and timed out repeatedly
  during the session. The other phone had previously logged one registration
  `200` and `403`s for additional refs. Thus the reverse direction also lacks a
  confirmed wake registration on this phone. Edge access/APNs logs were not
  pulled, so there is no server-side confirmation of ring POSTs or fan-out.
- Both outgoing attempts in this diagnostic window ended within about 6–10 s.
  The daemon recorded `media.session.start`, then only a stop message; there is no
  call-start message. The FFI stage markers were absent in the captured log, so
  it is not yet clear whether Swift never called the publisher or the FFI log
  filter hid its markers. New Swift markers now bracket the call into and return
  from the FFI, and the FFI markers distinguish endpoint/broadcast/ticket stages.
- For these later attempts, `AudioIO` logged that `engine.start()` returned
  `isRunning=true` and the ring loop was re-armed. That does not prove a sample
  reached the speaker: the earlier `lastRenderTime` check only covered the
  non-deferred path. A render check after re-arm is now logged. The earlier
  configuration-change/recovery stall was not reproduced in these attempts.
- These attempts were made with the apps active (`appState=0` at camera start).
  They do not test a locked-screen wake. They show that the current issue happens
  earlier than CallKit presentation.

## Regression and investigation ledger

**Updated:** 2026-11-09. Keep this table current after each device reproduction.
“Confirmed” means supported by the captured log/config; “open” means the symptom is
real but the failing stage is not established.

| ID | Problem | Status / evidence | Next step |
|---|---|---|---|
| C1 | Outgoing ringback inaudible | **Audio-queue race fixed; player render confirmed, acoustic check open.** On the first Gemini38 run, re-arm logged `lastRenderTime=nil` and `playing=false`; a queued stop cleared the loop. On the next run, output route was Speaker, loop RMS was 0.0732, and `sampleTime=22491 playing=true engine=true`. | `playLooping` now runs on the AudioIO queue, ordered after stop/start. User confirmation of audible ringback remains outstanding. |
| C2 | No CallKit/PushKit ring from user's phone to wife's | **Configuration confirmed, not a code regression.** Latest caller trace says `callMode=bar` and `outgoing presentation=Bar`; the wife peer has no saved mode entry on that phone. Bar deliberately suppresses CallKit and PushKit. | Select **System call** on the caller's local contact record. For two-way system ringing, both phones need the setting on their own copy of the other person's contact. |
| C3 | Gemini38 text replies but voice is unavailable | **Endpoint restored; LLM text turns reach the phone.** The phone receives `eve_call_return` and caller/agent transcripts. In the 04:36 run, local teardown began at 04:36:17 and the final answer text arrived at 04:36:20. The later 05:30 run shows repeated agent text replies; voice synthesis failed (C12). | Resolve the TTS provider failure and verify spoken output; retain supervision for `EVE_INSTANCE=voice` so the stable endpoint remains available. |
| C4 | User's phone cannot be woken by APNs | **Open; likely shares the observed network issue.** PushKit registration retried and timed out; at 03:18 it also logged a lost network connection. At the same time, iroh PKarr publication logged `Socket is not connected` (OS error 57). The other phone had previously logged one registration `200`; its latest logs were unavailable. | Verify edge registration and APNs result for each identity; retry after the phone's route is stable and pull edge access/push logs. |
| C5 | Wife-phone logs unavailable | **Open, tooling.** `devicectl copy from` lost its remote-device connection; no retry was made without new evidence. | Unlock/reconnect the phone, then copy its per-run app and FFI logs. |
| C6 | VoIP capability-ticket string rejected | **Fixed** in `1ecd2483`. The daemon returns rcan as a JSON string; the apps re-encoded it, quoting the token so registration and ring auth failed. iOS `PushWake` and mac `CallRing` now parse the token string and retain the legacy-object fallback. | No action; retain a registration/ring smoke test. |
| C7 | Camera/mic survived hangup or restarted after screen-lock interruption | **Fixed** in `ffe9ad25` and `1ecd2483`. Late async starts are epoch-guarded; camera stop is unconditional, and interruption/deferred restart is gated by explicit started state. | Device retest is still the acceptance check; do not infer from a successful build alone. |
| C8 | CallKit system actions silently did nothing | **Fixed**. The former generic delegate method did not satisfy typed `CXProviderDelegate` action requirements; typed `perform` overloads are now implemented. Details: `docs/troubleshooting.md` “CallKit Accept/Reject”. | Keep selector/action E2E coverage. |
| C9 | PushKit callback selector/version mismatch and unreported-cancel penalties | **Fixed/hardened.** Exact classic selector plus the iOS 26.4+ VoIP callback are implemented; calls are reported before PushKit completion, including stale cancel cases. Details: `docs/troubleshooting.md` “VoIP pushes stop reaching a locked iPhone”. | Keep locked/force-quit and quick-cancel E2E coverage across supported iOS versions. |
| C10 | Stale stop ended a later call | **Fixed** by generation-ticket correlation in `CallLifecycle` (historical #60). | Keep the pure lifecycle check and quick-redial device case. |
| C11 | No local answer beep on Gemini/serverCascade | **Cue enabled and observed as requested.** The old policy suppressed `answeredCue` because the holder was expected to greet on connect. The updated app logged `call-tone: answered` and re-armed the one-shot on the latest return invite; speaker rendering of the beep itself is not instrumented. | Confirm audible connected cue on the next call; this cue is distinct from the LLM's spoken reply. |
| C12 | LLM text arrived without agent voice | **Root cause confirmed.** The active holder uses `agents/voice/live.json` with `server-cascade`, matching the signed ticket. Its relay TTS returned HTTP 401 `quota_exceeded`: 1 credit remained while greeting/reply requests needed 5–66 credits. The bridge/LLM still produced text, but speech synthesis failed. Don has since selected on-device Nemotron STT and Phonon TTS for this contact; device verification is pending. | Verify that the on-device selection owns both audio halves on the next call; it should bypass the server relay's ElevenLabs TTS. |
| C13 | No visibility into LLM token supply or usage | **Sequential model routing is now rebuilt per instance; token-usage gap remains.** The Gemini `voice` instance was rebuilt with `google/gemini-3.8-flash`; starting `gpt6luna` detected the shared manifest mismatch and rebuilt it to `openai/gpt-6-luna` (`gateway`, target `openai`). The already-running voice process was left up. No per-turn token counts or gateway usage receipts are available. Vercel did not run out during this incident. | Add redacted per-turn provider/model, request ID, input/output token usage, and remaining budget when available. Never log prompt contents or credentials. The build output is shared, so do not start different model instances concurrently. |

| C15 | Persistent no-ring that survives code fixes | **Hypothesis; oracle-verified mechanism (2026-11-09).** Apple DTS: roughly 5 VoIP pushes that end in no reported call within ~24 h and iOS stops delivering background VoIP pushes to the app on that device (`VoIP push for app … dropped on the floor`); the counter clears via a daily `Ran nightly VOIP reconciliation` maintenance task (24–48 h+, later on busy devices), by reinstall, probably by app update. No query API, no APNs error. Fits "worked, then stopped a few days ago, still broken after the C6 fix": the C6 window sent *no* pushes, so feeders predate it (e.g. the #61 wedge class — push arrives with main wedged, delegate never runs, `0xbaadca11` kill counts as a failure). | Sysdiagnose immediately after a failed ring; grep `callservicesd`/`apsd` for the signatures above; then reinstall (or wait 48 h) and retest — rings again ⇒ suppression was the cause. |
| C16 | Report-skip paths can feed the suppression counter | **Code risk, not yet observed.** `CallKitController.presentIncoming` early-returns with no `reportNewIncomingCall` on `skip_redelivery` (same UUID), `skip_busy`, `skip_no_ids`; classic-delegate pushes carry `mustReport=true` unconditionally. Apple DTS: re-report the existing call UUID and let the duplicate rejection satisfy the contract — returning early "because my state says already-handled" is unsafe. | Report-and-let-reject on duplicate UUID; report-then-end for busy/no-ids pushes that must report. |
| C17 | Call invites have no multi-device failover | **Code fact.** `message.send` default delivery is One mode: `targets.truncate(1)` then `break` on error (`crates/idfon-daemon` `send`) — only the primary dial target is tried; `All` is the only failover mode. Call invites (`IdfonClient.sendText`) pass no policy → One. A stale primary (rotated endpoint) makes the invite unreachable while the account-keyed push still rings the phone → the 20 s pending-answer guard kills the call ("rings but answering drops it"). | Calls get their own delivery policy: fan out to all eligible devices, one explicit acceptance wins (RingRTC / `m.call.select_answer` pattern), late or duplicate accepts harmless. |
| C18 | Edge push ops gaps | **Code facts.** No `apns-expiration` on fan-out (late pushes cause ghost rings); `410 Unregistered` / `400 BadDeviceToken` never prune `PushStore` (dead tokens linger); environment routing flips only on the `BadEnvironmentKeyInToken` string (oracle: the documented mismatch reason is `BadDeviceToken`, and `BadEnvironmentKeyIdInToken` is a provider-key error — match raw reasons broadly, or register the env explicitly per token from the app's `aps-environment`). | Short expiry; prune on 410/BadDeviceToken; explicit per-token env; keep the flip as fallback. |
| C14 | gpt6luna contact did not answer | **Root cause confirmed; service restored.** At 07:29:42 UTC, iOS sent to peer `89f71f…` (the `GPT-6-Luna` contact); messages `msg_628` and `msg_629` failed with `connect timed out after 10s`. All processes in `~/.idfon/gpt6luna` were stopped. I restarted that instance with its existing holder key and pinned port 58159, preserving endpoint `89f71f…`; its Eve process is now `openai/gpt-6-luna` and bridge health is 200. The separate `~/.idfon/llm` endpoint `b0766318…` is the `eve` contact, not `gpt6luna`. | Verify the next user-placed call reaches the restarted service and Phonon speaks the reply. No re-pair is needed. |

These are distinct failure classes: a Bar-mode call has no push by design; an APNs
registration timeout prevents waking that device; and a missing start invite means
the receiver never reached the ring handler. Fixing only one does not close the
other rows.

### Gemini38 reproduction (2026-11-09)

Logs: `/tmp/idfon-gemini38-{app,ffi}.log` and
`/tmp/idfon-gemini38-try3-{app,ffi}-latest.log`. Clarification from Don: Gemini38
is the `google/gemini-3.8-flash` model selected in caller metadata for the local
`llm` agent; it is not a separate local agent instance for this contact.

- Routing selected `serverCascade`; the contact mode was `.bar`. `PushWake` logged
  `skipped ring for in-app-only channel`. Gemini38 is not an iPhone recipient, so
  this test did not exercise CallKit or APNs; no push was expected.
- The publisher did **not** stall. `media.session.start` was followed by
  `live publisher start entered`, endpoint setup returned in 27 ms, broadcast and
  ticket setup succeeded, and the publisher returned successfully.
- The daemon queued `msg_582` and `msg_583` to Gemini38, but neither was ACKed
  before the caller canceled about 9 seconds later. The next attempt's
  `msg_588`/`msg_589` and the following attempt's `msg_591`/`msg_592` all ended
  `Failed` after repeated `connect timed out after 10s` errors. No return invite
  arrived, so there was no answer/connected transition or answer cue.
- The caller phone also logged `/_push/register` timeout/network loss, PKarr
  publication failure `Socket is not connected` (OS error 57), `netwatch` AF_ROUTE
  socket errors, and an NWPath transition from Wi-Fi+cellular to Wi-Fi. These may
  have contributed, but the endpoint evidence is decisive: the phone's target
  `0267262c…` matches the stopped `~/.idfon/voice` holder ticket, not the separate
  active `~/.idfon/llm` instance (`b0766318…`). The endpoint ID did not rotate; its
  service stopped. The local `llm` holder log contains no new incoming call.
- **Endpoint persistence lesson:** `EVE_INSTANCE` selects the agent home that holds
  `holder.key` and the pinned UDP port. The `voice` instance repeatedly served as
  `llm` with endpoint `0267262c…`; the call failure followed service termination,
  not key rotation. Self-healing should restart the same instance/home and check the
  advertised holder ID before declaring it healthy. It must not silently substitute
  a different instance/ID or rewrite caller-side model metadata.
- Ringback was requested and re-armed, but 0.5 s later the audio log said
  `sampleTime=nil playing=false engine=true`. Source ordering explains it: on a
  fresh tone `CallTonePlayer.start` queued `stopPlayback`; `playLooping` then
  stored the deferred loop off-queue. Audio start re-armed that loop, then the
  queued stop cleared it. `AudioIO.playLooping` now serializes the whole operation
  on the audio queue. The installed build later logged a non-nil sample time with
  `playing=true`; the player rendered the loop, though user-confirmed audible
  playback is still outstanding.
- In the 05:30 UTC call, the app received `eve_call_return`, and the bridge logged
  agent text replies. The holder reported `backend=relay`; the active config is
  `agents/voice/live.json`, so `serverCascade` is not a stale-route mismatch.
  `~/.idfon/voice/live-relay.log` records greeting, filler, and reply TTS failures
  with HTTP 401 `quota_exceeded` (1 credit left, 5–66 required). This explains
  the text-without-speech symptom; it is not a PushKit failure. The app also
  logged `call-tone: answered`; physical rendering of that short cue remains
  unverified.
- The relay's text `forward()` uses `wrap.local=true`, sending the transcript to
  this instance's EVE agent. At the 05:30 call, its compiled manifest specified
  `openai/gpt-6-luna`, `routing.kind=gateway`, `target=openai`, and turn-time SDK
  warnings named the same model. That call therefore passed through to Luna, not
  Gemini. I rebuilt `agents/llm` with the instance's configured
  `EVE_IDFON_MODEL=google/gemini-3.8-flash`; the compiled manifest now specifies
  that model with `target=google`. I restarted only the Eve process on the same
  port; holder identity, ticket, and bridge were left intact. No prompt was sent
  to test the new model. The gateway remains Vercel AI Gateway.
- Don has changed the contact's STT/TTS selections to on-device Nemotron/Phonon.
  That should make the caller own both audio halves and bypass relay TTS; verify
  on the next call. Vercel did not run out of tokens during the previous incident.

## Platform semantics (oracle-verified, 2026-11-09)

Two `gpt-6.1-sol` oracle consultations (Apple push/call semantics; stable
addressing over rotating endpoints) plus a code audit. Verdicts marked
**documented** (Apple docs/WWDC), **DTS** (Apple engineer statements,
empirical), or **practice** (industry systems).

**Apple side:**

- **Report timing (documented):** `reportNewIncomingCall` must be submitted
  inline in the PushKit delegate before it returns (WWDC19 "Advances in App
  Background Execution"). An independent `callservicesd` check ~7 s after
  delivery kills with `0xbaadca11`. The PushKit completion handler does not
  substitute for reporting.
- **Report-then-end (documented):** fully satisfies the obligation for
  stale/cancelled calls; no minimum ring duration. Duplicate push for an
  already-reported call: re-report the same UUID and let the duplicate
  rejection count (DTS) — early return is unsafe (see C16).
- **`mustReport` (documented, iOS 26.4+):** the system's own marker. Classic
  delegates must assume every push needs a report.
- **Delivery suppression (DTS):** see C15 — the top suspect when no-ring
  persists across code fixes. Force-quit (swipe-away): VoIP pushes normally
  still relaunch the app (empirical; matches our E2E). Focus/DND can suppress
  ringing without any delegate failure; triage stages stay separate — APNs
  accepted → device received → delegate entered → report result → ringing →
  connection.
- **Tokens (documented/DTS):** `didUpdate`/`didInvalidatePushTokenFor` are
  authoritative; APNs `200` proves acceptance only (DTS: uninstalled apps can
  still 200); `410 Unregistered` carries a ms timestamp and must prune the
  registration (C18).
- **Environment (documented):** the *receiving* app's signed `aps-environment`
  decides sandbox vs production (dev profile → sandbox; TestFlight/App
  Store/ad-hoc/enterprise → production). A dual-environment `.p8` does not
  make a token valid in both. Inspect the installed app's entitlements.
- **Ops (documented):** `apns-expiration: 0` or a few seconds for calls;
  payload ≤ 5120 bytes; provider JWT refresh ≥ 20 min apart (ours: 50 min,
  good); test without a debugger attached. Cancel/update pushes are against
  Apple guidance (use the post-ring connection) — P2P has no such connection;
  keep them, but every one must end in a reported call.

**Addressing side (the "handles" question):**

- The account-key handle model (`docs/multi-device.md`: account signing key +
  signed device set + per-device transport keys) is the right shape — the same
  separation as Signal ACI/devices, Matrix MXID/device_keys, SIP
  address-of-record/contacts. **No further username/DNS/WebFinger layer is
  justified** for private manual contacts; reachability comes from current
  registration, not a nicer name.
- What a signed device set does **not** give: freshness and reachability. The
  industry repair for a stale roster is **rendezvous + a short-lived pending
  signaling record** (SIP RFC 8599 "push bucket": hold the request, push, wait
  for the client to re-register, forward). Ranked for idfon: account-keyed
  edge lookup > short-lived pending-call mailbox > proactive signed roster
  updates > authenticated inbound learning > re-pairing.
- **Multi-device call semantic (practice: RingRTC, Matrix
  `m.call.select_answer`, SIP forking):** offer to all eligible devices in
  parallel; exactly one *explicit user acceptance* arbitrates; losers end
  "answered elsewhere"; transport ack ≠ human acceptance. Calls must not
  inherit the generic sender's first-target-only policy (C17).
- **Ring must be self-sufficient (documented Apple shape):** the push carries
  enough to present the call; Answer is an intent to connect; signaling rides
  the edge while iroh connects; end truthfully if setup fails. The honest
  promise: *a valid call rings even when P2P signaling has not succeeded* —
  not *a call connects when every path fails*.

## Where the implementation is brittle

### 1. Ringing is downstream of media startup

`VideoCall.dialNow` starts the media session, starts local capture, synchronously
starts the live publisher through `media_live_start_with_profile`, then queues the
invite, then requests the edge ring. The push UUID is derived from the media ticket.
A slow or stuck publisher therefore suppresses both delivery paths. In the recent
logs, the daemon's `media.session.start` record was not proof that the live publisher
had produced its ticket or that the invite had been queued.

### 2. “CallKit mode” is per contact, not a global guarantee

`IncomingCallRouter` defaults an unknown or unset peer mode to `.bar`. The caller's
stored mode selects the CallKit outgoing path and gates PushKit ring creation. In
Bar mode, an active app can receive an iroh invite and ring in-app; a suspended app
cannot be expected to receive that invite. A successful build or a PushKit token
alone does not mean a given contact is configured for system ringing.

### 3. Push delivery depends on operational state outside the call state machine

The edge must have a registered token for the addressed identity and correct APNs
credentials, topic, and environment. App registration has its own retry loop and
capability-ticket auth. APNs acceptance is not proof the device delegate ran; the
edge's `rung` count, registration state, app callback log, and CallKit report outcome
are separate checkpoints. The latest logs demonstrate registration can be partial
(success for one ref, failure for another).

### 4. PushKit and CallKit impose immediate, version-sensitive delegate contracts

`PushWake` supports both the classic PushKit callback and the newer iOS 26.4+
VoIP-specific callback. Each must report the call before completing PushKit; the
callback uses exact imported/Objective-C selectors. A signature that compiles but
fails to satisfy the protocol can silently stop delivery. The app must report the
push promptly even when the invite is late, then reconcile the reported call with
the invite, answer, and cancel. That creates intentional report-then-end and
pending-answer races.

### 5. CallKit mirrors a second lifecycle

`CallKitController` mirrors `CallLifecycle` while tracking owner (`live`, `video`,
`agent`), UUID, system-originated answer/end, outgoing connect/connected reports,
and a pending answer. The typed `CXProviderDelegate` action methods, action
completion deadlines, report-before-end ordering, stale-call dedupe, and provider
reset cleanup are correctness requirements, not cosmetic UI code. The call machines
and CallKit can disagree temporarily; every mismatch needs a deterministic
reconciliation rule.

### 6. Audio has an ownership handoff too

On CallKit calls, the app configures the inactive `AVAudioSession`, CallKit activates
it, and `AudioIO` starts or resumes on `didActivate`. It must not race CallKit by
activating/reconfiguring the session itself. Cellular interruption, engine restart,
ring playback, and teardown while suspended add lifecycle paths independent of the
network invite. This is a known high-risk seam even when the ring UI succeeds.

### 7. The system cannot turn logs into an end-to-end answer today

The logs need a shared attempt ID and explicit markers for: mode decision, media
publisher start/return/error, invite operation ID and delivery status, ring POST
status plus `rung`, APNs response, PushKit callback/completion, CallKit report result,
answer, media-ready, and cancel/end. Without these, “no ring” conflates “no invite,”
“no APNs request,” “APNs accepted but not delivered,” and “CallKit declined the
report.”

## Options

| Option | Locked/suspended phone | Complexity | Main tradeoff |
|---|---|---:|---|
| **CallKit + PushKit, hardened (recommended)** | Native incoming call UI and supported VoIP wake, provided registration and the whole chain are healthy | High | Keeps the intended phone-call experience; requires the full lifecycle and APNs operations to stay correct |
| **In-app Bar only** | No reliable wake; works when the app is already receiving iroh events | Low | Simplest and preserves current P2P model, but explicitly gives up locked-phone ringing |
| **Visible standard notification** | Can show a notification on the lock screen; user taps to open/answer | Medium | Useful fallback when CallKit is unavailable or disabled; not a live CallKit call and not an automatic background join |
| **Silent-push auto-connect** | Not a dependable call wake | Medium | Background delivery/execution is discretionary and time-limited; do not promise ringing or auto-answer from it |
| **Third-party VoIP provider/SDK** | Usually still needs the platform's supported call/push integration for native locked-screen calls | High / recurring | Can replace media/signaling and operational burden, but adds vendor dependence and may conflict with Idfon's P2P, identity, or end-to-end security goals |

A visible notification is an **alert-and-tap fallback**, not a substitute for CallKit's
incoming-call lifecycle. Silent APNs should not be treated as a way to bypass CallKit
and reliably start live audio while the phone is locked. A third-party SDK can move
parts of the stack; it cannot make iOS's background execution model disappear.

## Recommended hardening plan

### P0 — Close the current observability gap

- **Verify or kill the suppression hypothesis first (C15):** sysdiagnose after
  a failed locked-screen ring, grep `callservicesd`/`apsd` for the
  `dropped on the floor` / `failed to report` / `nightly VOIP reconciliation`
  signatures; then reinstall (or wait 48 h) and retest. This decides whether
  any code change can help at all.
- **Harden the report path (C16):** every push that must report ends in a
  `reportNewIncomingCall` call — duplicate UUIDs re-report and let the
  rejection count; busy/no-ids pushes report-then-end.
- **Edge push ops (C18):** short `apns-expiration`, prune tokens on
  410/BadDeviceToken, explicit per-token environment.

- Log before and after `media_live_start_with_profile`, including elapsed time,
  returned-ticket presence, and `media_live_last_error`.
- Check whether the native FFI call itself can block without a deadline. A Swift
  task timeout cannot cancel a synchronous C call already running; if the FFI has
  no bound, add a native timeout or expose an async start/status/cancel seam before
  promising a caller-visible timeout. On timeout/failure, stop partial media and
  capture, and show a clear “could not start call” state. Do not leave ringback or
  capture running.
- Add one call-attempt ID across app, daemon operation, edge ring, and receiver logs.
- Make token health visible per identity: last registration result/time, token topic,
  APNs environment, and whether the edge has a registered device. Never log the
  token itself.

### P1 — Decouple call control from media readiness

Generate an opaque call-attempt UUID before media setup. Send a small authenticated
call offer and ring request using that UUID while media publishing proceeds. Carry
the media ticket separately when it becomes available. The receiver may present the
CallKit ring immediately, retain an early answer, and join only when the media offer
arrives. If publishing fails, send an explicit cancel/end for the same UUID. Keep
media authorization ticket-based; the call UUID is correlation, not authority.

Extend the edge's `/_push/*` service into the **pending-call rendezvous** the
wake needs (oracle 2, 2026-11-09): the caller submits an authenticated,
expiring call record addressed to the account *before* ringing; the edge
persists it, fans the ring out; the woken callee pulls the record and answers
with its **current endpoint** (or connects outbound to the caller) — so the
call survives a stale roster, endpoint rotation, and slow media startup
(SIP RFC 8599 push-bucket shape). Offer to **all** eligible devices in
parallel with one explicit acceptance winning; transport acks never stop the
account-level ring.

This is a protocol/state-machine change. It must preserve: same-UUID dedupe between
PushKit and iroh, PushKit's report-before-completion rule, answer-before-offer,
quick cancel, stale-stop isolation, retry/idempotency, and multi-device ring-over.
A smaller timeout/logging fix is useful but does **not** remove the architectural
coupling.

### P2 — Treat PushKit as an observable delivery chain

Keep the single long-lived `PKPushRegistry`; retry and expose registration failure;
verify each identity's edge registration, correct topic and sandbox/production
routing. Retain the two delegate variants and same-turn CallKit report. Add device
E2E coverage for force-quit/locked ring, invite-first and push-first races, quick
cancel, answer from lock screen, system decline, audio activation/interruption, and
registration loss/recovery.

### P3 — Make fallback semantics explicit

Keep `.bar` as a documented foreground-only choice. Offer standard alert notification
only if a user-facing tap-to-answer fallback is wanted. Do not silently change a
failed CallKit/PushKit attempt into “auto-connect”; report the failure and preserve
user consent.

## Documentation caution

The later generic section in `docs/callkit-integration.md` describes “high-priority
silent APNs” auto-connect as a background workflow and includes broad claims about
other apps and CallKit bugs. Those statements are not supported by this repository's
implementation or tests and should not be used as architectural requirements. The
options above supersede that section's implied reliability claims; remove or replace
that generic material in a separate cleanup.

## Decision

**Do not replace CallKit to fix the recent no-ring incident.** The evidence shows the
calls stopped before the invite and push steps, so swapping the presentation layer
would not address it. First instrument and bound native publisher startup; then
separate call-attempt signaling from media-ticket readiness if locked-screen
ringing must work even when media startup is slow. Keep Bar as the intentionally
limited low-complexity mode.

**Endpoint rotation is not the primary no-ring cause:** the account-keyed push
registry already survives it. The real gaps are roster freshness, invite fan-out
(C17), and the platform-side suppression state (C15) — see "Platform semantics"
and `docs/multi-device.md` for the handles verdict.

**Primary references:** `ios/Idfon/IncomingCallRouter.swift`,
`ios/Idfon/VideoCall.swift` (`dialNow`), `ios/Idfon/PushWake.swift`,
`ios/Idfon/CallKitController.swift`, `docs/callkit-integration.md`,
`docs/multi-device.md`, `docs/troubleshooting.md`.
