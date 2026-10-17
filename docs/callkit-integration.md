Apple’s **CallKit** framework and **iroh** (the peer-to-peer networking library built by n0) can be integrated, but they operate at completely different layers of the software stack:

* **CallKit** handles the **iOS system UI** and phone integration (presenting native incoming/outgoing call screens, syncing with system call history, managing mute/hold states, and respecting system behaviors like Do Not Disturb).
* **iroh** handles the **P2P transport layer** (establishing peer-to-peer connections using QUIC, hole punching through NATs, end-to-end encryption, and low-latency audio stream delivery).

Because they perform separate roles, they can be wired together to build a native iOS VoIP application.

---

## Implemented seam in this repo

The dual-mode decision is captured in `docs/ui-design-notes.md` §6 and is already wired
end-to-end short of CallKit itself:

* Each daemon peer record carries `call_mode` (`"bar"` | `"call_kit"`, default `"bar"`),
  settable via `peer.add` / `peer.update` and the CLI (`idfon peer add|update --call-mode`).
  See `docs/protocol.md`.
* `ios/Idfon/IncomingCallRouter.swift` is the single routing point: a fresh incoming
  invite resolves the **sending channel's** mode; a `call_kit` channel is reported to
  CallKit **and** handed to the machines (the mode governs presentation, not
  transport), every other channel takes the Bar path (`LiveCall` + `VideoCall`).
* `CallKitIncomingPresenter.isAvailable` is `true` — P1 landed
  (`ios/Idfon/CallKitController.swift`, `CXProvider` + `CXProviderDelegate`, mirroring
  the machines via their `notify()` funnel). A channel whose CallKit report fails falls
  back to the Bar (`forceBarFallback`, an explicit switch, never a silent mode change).
  **No in-app UI sets `call_mode` yet** — it is settable via `peer.add`/`peer.update`
  and the CLI over the app's socket (the doc's old "Incoming calls" menu never existed
  in code; the mode-setting UI is a P1 follow-up).
* macOS presents in-app today, and its system-call surface is **not** `CXProvider` —
  it is **LiveCommunicationKit** (`ConversationManager`), CallKit's shape one
  generation later. That lands as plan phase P3 (deferred); the mac app has no routing
  seam yet (`ChatStore` feeds `LiveCall`/`VideoCall` directly,
  `mac/Sources/Idfon/Calls.swift`). Wire values keep the `call_kit` name — it names the
  mode family, not the framework.

Not implemented: PushKit VoIP registration and token handling, the APNs payload split,
and the macOS LiveCommunicationKit presenter. The I/O notes below still apply to that
work.

---

## Implementation plan

Status: **P1 landed** (as-built details in "Implemented seam" above); **P3 deferred**
(mac later). P2 is next. Three separable problems, shipped as three phases:

* **P1 — CallKit owns the call lifecycle** while the app process is alive (foreground
  or background-alive during a call). No backend, no push, no new entitlements beyond
  the background mode. Delivers system call UI, call history, headset/CarPlay buttons,
  cellular-interruption handling, and the `AVAudioSession` handoff.
* **P2 — PushKit ring** for apps that are suspended or terminated: the lock-screen
  ring that is the actual point of `call_mode: "call_kit"` ("reaching people who
  aren't here", ui-design-notes §6). Needs an always-on pusher: the `idfon.net` edge
  droplet.
* **P3 — macOS system-call UI via LiveCommunicationKit**: same feature on the mac,
  through `ConversationManager` instead of `CXProvider` (no Catalyst — native
  AppKit). The mac app is usually alive, so P3 alone rings mac users; P2's push
  wake extends to it.

P1 is only half the promise without P2 (a dead process hears no iroh invite), but it
is the entire CallKit integration surface and is testable in isolation; P2 is mostly
infrastructure. Keep them separately shippable.

### P0 — provisioning

* **Xcode automatic signing registers APNs at build** (decided 2026-10-16): the target
  declares the capability (`ios/Idfon/Idfon.entitlements`, `aps-environment`;
  `CODE_SIGN_ENTITLEMENTS` in the project) and Xcode creates or updates the
  `com.idfon.ios` App ID and provisioning profile itself. No manual dev-portal step
  for the app.
* Still manual, P2-only: the **APNs auth key** (`.p8` + key id + team id) the edge
  pusher signs VoIP pushes with — a Keys & Identifiers artifact, kept in ops secrets,
  never the repo.
* `voip` joins `UIBackgroundModes` with the P2 PushKit code (the mode is justified by
  the registration that uses it).
* Distribution note: CallKit is banned by the Chinese App Store (see below). Not a
  problem until China distribution is on the table — same bucket as MAS vs Developer ID.

### P1 — CallKit call ownership (app alive)

New `ios/Idfon/CallKitController.swift`: `CXProvider` + `CXProviderDelegate`, one
instance at app start. Flipping
`IncomingCallRouter.CallKitIncomingPresenter.isAvailable` to `true` and implementing
`present(peerId:text:)` is the entire landing seam.

1. **Incoming** (`CallKitIncomingPresenter.present`): parse the `IDFON-LIVE/1` /
   video invite envelope exactly as the Bar path does, then `reportNewIncomingCall`
   **synchronously in the same turn as the envelope receipt** — never after an await.
   The call `UUID` is derived deterministically from the invite ticket (hash → UUID),
   so re-delivered invites map to one CallKit call and the ghost-call rule below can
   dedupe. `CXCallUpdate`: peer display name, `.generic` handle, `hasVideo` from the
   invite's `media` line.
2. **Answer** (`didPerform CXAnswerCallAction`): route to the existing
   `LiveCall.answer()` / `VideoCall` answer — the state machines stay the source of
   truth and CallKit mirrors them. With one exception: on the CallKit path `AudioIO`
   must **not** configure/activate `AVAudioSession` (see 6).
3. **Outgoing**: a call dialed on a `call_kit` channel goes out via
   `CXCallController.request(CXStartCallAction)`; media publish + invite send happen
   in `didPerform CXStartCallAction`, mic start in `didActivate` (below). Decision:
   the mode covers both directions on a channel — an answered CallKit call continuing
   as a non-CallKit outgoing call on the same channel would be incoherent.
4. **Mute sync**: `CXSetMutedCallAction` ↔ `LiveCall.setAudioEnabled` /
   `VideoCall.setVideoEnabled`, both directions (Bar toggles also request the CX
   transaction so the lock-screen state can't desync).
5. **End**: `CXEndCallAction` ↔ `terminate(local:)`; peer-side `call_stopped` or a
   broken session → `reportCall(with:endedAt:reason:)`. `providerDidReset` tears
   everything down unconditionally (the stuck-green-banner fix). On app termination
   with a live call, report the call ended (`recoverStaleCall` already exists as the
   startup-side recovery).
6. **Audio handoff**: `AudioIO` gets an "external session owner" mode — on the
   CallKit path it skips `setCategory`/`setActive`/interruption handling entirely;
   capture + playback start only in `provider(_:didActivate:)` and stop in
   `provider(_:didDeactivate:)`. Starting audio earlier is the documented
   one-way-audio bug. `CallTones` is silent on this path (the system ringtone).
7. **No double-presentation** (ui-design-notes §6): when CallKit owns the ring the
   Bar never enters `.incoming`; it renders only the answered/active call. The
   deferral behavior for unavailable CallKit stays exactly as-is.
8. **Races to design against** (the verified bug list below): serialize all
   `CXTransaction` requests on one queue and never touch a call UUID before its
   start/answer action completed (unknownCallUUID, code 4); a superseded invite or
   early `call_stopped` ends the CallKit call **in the same turn** it was reported
   (ghost-call flash); cellular-interruption `didDeactivate` must leave the call
   resumable, not frozen.

Checks/tests: extend `ios/Checks/` with host-runnable checks for the pure seams
(ticket→UUID derivation, invite→`CXCallUpdate` mapping); the rest is manual device
E2E via `scripts/ios-call-e2e.sh` + runbook: system-UI answer/decline, mute from the
lock screen, BT headset buttons, cellular interruption, quick cancel (ghost call),
hangup both directions, force-quit while in call.

### P2 — PushKit ring (app suspended or terminated)

The callee's process is dead, so somebody else must ring it. The only always-on
party in the topology is the **idfon.net edge droplet** — it carries the push
service and the APNs auth key (`.p8`, key id, team id, topic
`com.idfon.ios.voip`; secrets in ops, never the repo).

**Landed (edge)** — `crates/idfon-edge/src/push.rs`, served on the edge's own
listener through the gateway's `LocalRoute` hook (`crates/idfon-gateway`), so the
routes share the edge's TLS/origin and address like any edge resource
(`https://<ref>.idfon.net/_push/…` or `https://idfon.net/<ref>/_push/…`). No
daemon or protocol change: everything is HTTP plus the capability tickets the
apps already hold.

| Route | Body | Auth |
| --- | --- | --- |
| `POST /_push/register` / `unregister` | `{voip_token, topic?}` | a capability ticket **issued by the ref** — the app self-issues one through the daemon's existing `capability.ticket` RPC, so only the identity's holder can claim its wake channel |
| `POST /_push/ring` | `{call_uuid, caller_id, has_video}` | a capability ticket **issued by the ref** (the caller's contact ticket — being a contact is the right to ring) **or by the caller** (a self-issued statement: identified + rate-limited, so a plain paired peer can ring before a contact ticket exists). A subject-bound ticket must match `caller_id` |
| `POST /_push/cancel` | `{call_uuid}` | same as ring |

Fan-out sends one VoIP push (`apns-push-type: voip`, topic `com.idfon.ios.voip`,
priority 10) per registered token; the payload carries **identifiers only**
(`call_uuid`, `caller_id`, `has_video`, `cancel`) — the app resolves display
names from its own peer store, keeping peer names out of APNs logs. Tokens
persist to `--push-state` (default `<key>.push.json`); APNs is configured with
`--push-apns-key/--push-apns-key-id/--push-apns-team` (optional topic/url), and
with no key the routes answer 503 instead of dropping rings silently. Per-issuer
rate limit 30/min. Verified: `cargo test -p idfon-edge` (register/ring fan-out,
wrong-issuer and subject-mismatch refusal, expiry, cancel, unregister, 503).

**Bundle ids and the identity layer.** `com.idfon.ios` and `com.idfon.mac` are
two separate APNs apps, and that costs nothing at the identity layer: the
registry keys on the endpoint ref, so ring-all spans every device and platform
of one idfon identity, and tickets/`callUUID`/`call_mode` never see the bundle
id. What the bundle id does dictate is the APNs envelope: tokens are per app
bundle and every push carries its token's topic (`<bundle-id>.voip`), which is
why registration stores `token → topic` and fan-out varies the topic per token.
One team-level `.p8` auth key signs for **all** apps — no second key when the
mac joins (P3). The one leak to remember is the APNs *environment*: dev-signed
builds deliver only via `api.sandbox.push.apple.com`, so a dev edge sets
`--push-apns-url` there; an edge serving mixed sandbox/prod tokens would need
per-token environment (not built).

**Names and the call log (decided 2026-10-17, donpark/idfon#48).** The system
call UI shows real peer display names, which land in the system call log
(Recents) and sync to iCloud. Deliberate: idfon contacts are user-chosen
labels, not phone numbers, and the call log is the user's own device log.
Signal's placeholder-name posture is not ours (`includesCallsInRecents` stays
on). If a "hide from call log" preference is ever wanted, that is the switch.

**Landed (iOS + mac caller side)** — `ios/Idfon/PushWake.swift`, the
`CallKitController` push hooks, and `mac/Sources/Idfon/CallRing.swift`:

1. **Registration**: `PushWake.start()` at launch registers the PushKit token
   under every id this device is known by with topic `com.idfon.ios.voip`,
   signed by a self-issued `capability.ticket` (retries while the core boots);
   `didInvalidatePushTokenFor` unregisters. Multi-device: ring-all.
2. **Ring/cancel**: both apps post `/_push/ring` (`call_uuid =
   CallUUID.from(invite ticket)`) right after the invite is queued, gated on
   `call_kit` channels only; the `notify()` funnel posts `/_push/cancel` when a
   call that rang goes idle without connecting and clears the ring on connect.
   **`caller_id` derives from the presented ticket** — a contact ticket binds
   it as `subject`, a self-issued statement as `issuer` (the `sender.peer_id`
   message events carry): the identity key and the iroh endpoint id are
   different ids on some daemons, and any other derivation breaks the edge's
   ticket checks. Shortcut: the caller posts to its *own* configured edge
   (`EdgeClient` config) — shared-edge deployments only (idfon.net);
   cross-edge discovery is follow-up.
3. **Wake**: on iOS 26.4+ the push arrives through
   `pushRegistry(_:didReceiveIncomingVoIPPushWith:metadata:withCompletionHandler:)`
   — implementing only the classic delegate means the push is **dropped
   before the app** on iOS 27 (verified on hardware). The delegate reports
   `presentPush` in the same turn (payload `call_uuid`; names resolve from the
   persisted multi-ref peer cache — never a raw id hash, "Idfon caller" until
   the live records refine the UI) and the invite envelope dedupes onto the
   pushed call via the P1 UUID mapping. An answer that beats the envelope arms
   a pending answer completed by `envelopeArrived()` (a 20 s guard ends the
   call if the invite never lands).
4. **Cancel**: caller hangs up before answer → `/_push/cancel` → second push →
   end in one turn (the graceful de-escalation pattern). A stale cancel for a
   call that is already gone must not resurrect one: only a `mustReport` push
   (the iOS 26.4+ metadata flag) needs a reported call at all.
5. **Honest limitation**: a `bar`-mode channel gets no wake. That is by design
   (ui-design-notes §6: the Bar is for people who are already here) and stays out of
   scope — no alert-push fallback.

Checks/tests: edge unit tests landed (above). Device E2E proven (2026-10-17,
iOS 27.0.1, sandbox APNs): token registration, mac→phone ring with the app
force-quit on the lock screen (cold launch → system call UI), cancel →
same-turn dismiss, stale cancel → no-op, caller names resolve. Remaining:
answer → two-way audio in the same flow, a video ring, and the
ring-with-app-alive double-present check.

### Open threads (updated 2026-10-17 — pick up here)

Tracked as donpark/idfon issues; the session that hunted the wake bugs left
these:

- **#61 (open, the current blocker):** the push-woken app wedges on main
  during message ingest (`ChatStore.notifyObservers` → a chat-observer
  callback — table rebuild / timeline parsing), which also hangs the CallKit
  answer action. The known trigger (a `IDFON-SESSION/1` rotate ingested as
  chat) is fenced (commit `3eeae06`); if the freeze reproduces, the observer
  forensics are the next step (all three observers are UI classes; move their
  work off main or gate it).
- **#60 (open):** out-of-order legacy `call_stopped` from a killed attempt
  terminates the next call — the "call cut off after 2s" cause. Mitigated by
  a per-peer invite-sequence watermark (commit `5c4dafa`); the proper fix is
  ticketed stops correlated to the call generation.
- **#55 (open):** the woken app dying within seconds (SIGKILL). Suspect
  overlap with #61 (a wedge looks similar from outside) — re-verify only
  after #61 is resolved.
- **#51 (open):** answer → two-way audio — the last functional leg.
- **#52 / #54 (open):** host checks for the bitten seams; test-config
  residue + droplet deploy checklist.
- **#56 (open):** contact-ticket `account_id` vs `sender.peer_id` — pairing
  from the advertised ticket can never pass the message gate. Workaround:
  pair with `account_id` overridden to the sender's `sender.peer_id`.

**Wake chain status (verified on hardware):** registration, push → system
ring (survives — the five ring-killers are fixed: report-then-end race #58,
mode-cache regression #57, stale-ring block #59, phantom cancels (test
tooling), straggler call_stopped #60-mitigation), cancel → same-turn dismiss,
stale-cancel no-op, caller names. Remaining: the answer-side freeze (#61)
and then the audio leg (#51).
- **Ring semantics (settled the hard way):** the **sender's** `call_mode`
  opt-in is the gate for system rings; the receiver-side gate was reverted
  (#47) because the wire collapses an unset `call_mode` into `bar`
  (`Peer.call_mode` is non-optional) — a tri-state wire field is the future
  work if receiver-side suppression is ever wanted. The no-double-present
  guards key on actual system-call state (`CallKitController.isRinging`),
  never on mode predictions; a new push ring supersedes a stale unanswered
  one (#59).

**Local E2E runbook (mac→phone wake):** run the edge with the push flags
(`--push-apns-key ~/.idfon/edge.apns.p8 --push-apns-key-id LRV4AV57QS
--push-apns-team RV27HPQNMF --push-apns-url
https://api.sandbox.push.apple.com --push-state /tmp/edge-push-e2e.json`);
both apps take `-edgeurl http://<mac-lan-ip>:<port> -edgeticket e2e`; the
phone needs a peer record for the mac app's daemon identity (pairing
workaround, #56) and the mac needs `peer update <phone> --call-mode call_kit`;
kill the phone app, then
`mac/build/Idfon.app/Contents/MacOS/Idfon -edgeurl … -dial iphone`. Pull the
woken app's trace with `devicectl device copy from --domain-type
appDataContainer --domain-identifier com.idfon.ios --source
tmp/idfon-app-<pid>.log` (pid from `device info files --subdirectory tmp`;
`--console` only attaches to foreground launches). Ring cancel curls must
send `"cancel": true` — without it the edge treats them as rings.

The mac already **sends** rings (`CallRing.swift` — caller-side plumbing is
shared by any idfon app); what P3 adds is the mac's own wake + presentation.
The ring fan-out reaches macOS once P3 lands: PushKit VoIP exists natively on macOS
(`didReceiveIncomingVoIPPushWithPayload:metadata:`, `macos(26.4)`). A mac registers
its token only once its LiveCommunicationKit presenter exists — a VoIP push that
arrives with nothing to report to is the same process-kill hazard as on iOS.

### P3 — macOS: LiveCommunicationKit (deferred — mac version later)

macOS has no `CXProvider`; its system-call surface is **LiveCommunicationKit**
(iOS 17.4 / watchOS 10.4 / macCatalyst 17.4). It is CallKit's design one generation
later; the P1 mapping is mechanical:

| CallKit (iOS, P1) | LiveCommunicationKit (macOS) |
| --- | --- |
| `CXProvider` + `CXProviderDelegate` | `ConversationManager` + `ConversationManagerDelegate` |
| `CXCallUpdate` | `Conversation.Update` |
| `reportNewIncomingCall` | `reportNewIncomingConversation(uuid:update:)` |
| `CXStartCallAction` / `CXAnswerCallAction` | `StartConversationAction` / `JoinConversationAction` |
| `CXEndCallAction` / `CXSetMutedCallAction` | `EndConversationAction` / `MuteConversationAction` |
| `reportCall(with:updated/ended:)` | `reportConversationEvent(_:for:)` (`conversationUpdated`/`StartedConnecting`/`Connected`/`Ended`) |
| `providerDidReset` | `conversationManagerDidReset` |
| PushKit payload → report | `ConversationManager.reportNewIncomingVoIPPushPayload(_:)` |
| call history | `ConversationHistoryManager` (`includesConversationInRecents`) |

Differences that matter:

* **No audio handoff.** LCK has no `didActivate`-style audio-session callback — it is
  presentation-only, and the mac app keeps owning its audio path exactly as today.
  The P1-6 seam is iOS-only.
* **Explicit action fulfillment.** Actions are `fulfill(dateStarted:/dateConnected:/
  dateEnded:)` / `fail()` — the same unknown-UUID race applies, so the same
  one-queue serialization rule carries over verbatim.
* **Toolchain gate — checked 2026-10-16, not yet open.** Xcode 27.1 / macOS 27.0
  SDK: the core classes typecheck `@available(macOS, unavailable)` for native targets
  at every deployment target 26.0–27.1. Apple's current docs list the framework as
  iOS/iPadOS/Mac Catalyst/visionOS/watchOS — no macOS entry. The one sign of
  enablement work: `StartConversationAction` in the macOS SDK interface carries a
  contradictory `macCatalyst 17.4, macOS 26.0, *)` **and** `@available(macOS,
  unavailable)` pair. Re-verify with one typecheck per Xcode release; if it never
  flips, P3 falls back to either a Mac Catalyst variant of the call surface
  (CallKit typechecks clean under Catalyst today) or the mac keeps the Bar — decide
  at P3 start, the mapping below is the same either way. Do not block iOS P1/P2 on it.

Mac code shape: `Calls.swift`'s `LiveCall`/`VideoCall` stay the source of truth;
`ChatStore` currently feeds them directly, so add the same `IncomingCallRouter` seam
iOS has (per-channel `call_mode` from the daemon peer records via `DaemonClient`),
routing to a `LiveCommunicationKitPresenter`. The no-double-presentation, ghost-call,
and same-turn-report rules from P1 apply verbatim.

### Not in scope

China CallKit-stripped build variant, Siri/`INStartCallIntent`, CarPlay,
Recents-directory customization, per-device ring preference, alert-push fallback
for `bar` channels — all deferred, none blocking.

### Rebuild scope

P1: iOS app only. P2: `idfon-protocol`/`idfon-daemon` (+ vendored libs per
`docs/build.md`), the edge service, and the iOS app. P3: macOS app (+ daemon-side
push registration when the mac joins P2).

**Integration Architecture**

**1. Foreign Function Interface (FFI)**
Because iroh is written in Rust and CallKit is a Swift/Objective-C framework, you need an FFI bridging layer:

* **UniFFI** or **Swift-Bridge**: Compile your Rust iroh networking/media logic into a static library (`.a` or `.xcframework`) and expose Swift-friendly bindings.

**2. Push Notifications & Call Triggering**

* **Incoming Calls**: Your app receives an Apple **PushKit (VoIP) notification**. Upon receipt, Swift code passes the payload to CallKit via `CXProvider.reportNewIncomingCall()`.
* **Connection Handshake**: Simultaneously, your app initializes an iroh endpoint using the peer’s public key (Node ID) to start the P2P connection handshake.

**3. Call Lifecycle Binding**
You link CallKit actions to iroh streams inside your Swift `CXProviderDelegate`:

* **`provider(_:perform:CXAnswerCallAction)`**: CallKit reports that the user answered. You start decoding audio (e.g., using Opus) and send/receive audio frames via iroh streams (or QUIC channels like `iroh-roq`).
* **`provider(_:perform:CXEndCallAction)`**: The user hangs up. Swift notifies your Rust runtime to close the iroh connection and shut down audio streams.
* **`provider(_:didActivate:AVAudioSession)`**: CallKit delegates control of the iOS audio hardware. Pass audio input/output buffers into your media pipeline before piping them through iroh.

---

**Key Challenges to Keep in Mind**

* **PushKit Requirement**: Apple requires that *every* VoIP push notification immediately results in a CallKit incoming call screen. You must report the call to CallKit instantly, even while iroh is negotiating NAT traversal or hole punching in the background.
* **Audio Session Management**: CallKit owns `AVAudioSession`. You must wait for CallKit to signal that the audio session is active before capturing or playing microphone audio over your iroh stream.
* **Background Execution**: Once connected, iOS keeps the VoIP call alive in the background, but iroh’s QUIC connections must handle quick reconnection or relay fallbacks if network conditions change mid-call.

===

When switching between CallKit and custom in-app handling, your backend must send two fundamentally different APNs payload structures and headers.

---

### Key APNs Configuration Differences

* **Header Requirements:** VoIP pushes require `apns-push-type: voip` and must be directed to the app's VoIP topic (`.voip` suffix). Standard alerts use `apns-push-type: alert` directed to the bundle ID.
* **Payload Structure:** VoIP notifications contain plain JSON metadata (APNs does not display anything). Standard alert notifications require an `aps` dictionary containing alert text and sound configuration so iOS can display a banner natively.

---

### Payload Examples

**1. CallKit Path (VoIP Push)**

Sent when CallKit is enabled. This wakes the app in the background, where iOS expects `CXProvider.reportNewIncomingCall` to be invoked immediately.

```http
POST /3/device/{device_token}
apns-push-type: voip
apns-topic: com.example.yourapp.voip
apns-priority: 10

{
  "call_id": "a1b2c3d4-5678-90ab",
  "caller_name": "Jane Doe",
  "caller_handle": "+15550199",
  "has_video": false
}

```

**2. Non-CallKit Path (Standard Alert Push)**

Sent when the user opts out of CallKit or for non-call interactions (e.g., huddles). iOS handles rendering the banner on the lock screen or displaying a banner while the app is in the foreground.

```http
POST /3/device/{device_token}
apns-push-type: alert
apns-topic: com.example.yourapp
apns-priority: 10

{
  "aps": {
    "alert": {
      "title": "Incoming Call",
      "body": "Jane Doe is calling..."
    },
    "sound": "incoming_ringtone.caf",
    "category": "INCOMING_CALL_CATEGORY",
    "content-available": 1
  },
  "call_id": "a1b2c3d4-5678-90ab",
  "caller_name": "Jane Doe"
}

```

---

### Backend Logic Checklist

* **Sync Preference State:** Sync the user’s CallKit preference (`enabled`/`disabled`) to your backend database whenever it changes in the app.
* **Token Management:** Store two distinct tokens per device: the standard **APNs Device Token** and the **PushKit VoIP Token**.
* **Failure Prevention:** Never send a VoIP push (`apns-push-type: voip`) if the backend marked CallKit as disabled for that user. iOS will force-terminate your app if a VoIP push arrives and CallKit isn't invoked.

===

Your architectural pattern directly mirrors how platforms like **Discord (Huddles/Voice Channels)** or **Slack** operate. When users opt into a low-friction/auto-connect experience, bypassing CallKit completely is the correct choice.

---

### Non-CallKit Workflow: Low-Latency "Auto-Connect"

Rather than ringing the target user via a full-screen lock sheet, the system immediately establishes WebRTC/VoIP channels and presents the active conversation UI directly inside the app.

```
[ Sender Calls ] 
       │
       ▼
[ Backend Checks Receiver Settings ]
       │
       ├─► [ CallKit Mode Enabled ] ──► Send VoIP APNs ──► Display CallKit UI / Wait for Accept
       │
       └─► [ Auto-Connect Enabled ] ──► Send High-Priority Silent APNs 
                                               │
                                               ▼
                                      [ App Wakes in Background ]
                                               │
                                               ▼
                                      [ Join WebRTC / VoIP Channel ]
                                               │
                                               ▼
                                      [ Play Audio & Show In-App UI ]

```

---

### Key Technical Considerations for Non-CallKit Paths

* **Background Execution Limits (iOS Sandbox):** If the app is terminated or in the background when the request arrives, a standard silent notification (`content-available: 1`) will wake the app, but iOS **strictly limits background execution time** (typically ~30 seconds). The app must immediately connect to the RTC session and start playing audio via `AVAudioSession` before the system suspends it again.
* **Lock-Screen Limitations:** Without CallKit, you **cannot render custom full-screen UI over the iOS lock screen**. If the device is locked when an auto-connect session arrives, you can only play audio through the speaker/headphones and display a standard notification banner (`UNNotificationRequest`).
* **Session Ownership:** CallKit handles native call precedence (e.g., pausing music, handling incoming phone calls, audio interruption recovery). When bypassing CallKit, your app must manually manage `AVAudioSession.Category.playAndRecord` and subscribe to `AVAudioSessionInterruptionNotification` to manage audio state when a native phone call arrives.

===

Over years of real-world implementation, developers working with VoIP and WebRTC on iOS have documented a set of distinct, well-verified CallKit bugs and technical edge cases.

---

### **1. Audio & Media Pipeline Bugs**

* **The "One-Way Audio" Race Condition (`AVAudioSession` Misalignment):**
* **Issue:** When a user accepts a call via CallKit, the app must wait for iOS to execute the `provider(_:didActivate:)` delegate method *before* starting the WebRTC or audio engine. If the app activates the `AVAudioSession` too early, iOS revokes audio access, causing one or both callers to hear complete silence.


* **Microphone State desynchronization:**
* **Issue:** Toggling mute on the native CallKit lock screen often desynchronizes from the app’s internal mute state. If a user unmutes via a connected Bluetooth headset, CallKit may reflect the unmuted state while the app’s internal WebRTC audio track remains muted.


* **Bluetooth & AirPlay Route Hijacking:**
* **Issue:** During an active CallKit session, connecting or disconnecting a Bluetooth device (like AirPods) can cause CallKit to drop the audio route entirely rather than defaulting back to the iPhone speaker or receiver.



---

### **2. Notification & System-Enforced Crashes**

* **PushKit 1:1 Execution Requirement (`NSInternalInconsistencyException`):**
* **Issue:** Introduced in iOS 13, Apple requires developers to call `reportNewIncomingCall` on the same thread/runloop as an incoming PushKit VoIP notification.
* **Impact:** If network latency causes a delay in fetching caller info, or if the push was sent merely to update data rather than start a call, iOS terminates the app process instantly.


* **"Ghost Call" Loop on Quick Disconnects:**
* **Issue:** If a caller rings and immediately hangs up, the recipient’s app receives the push notification and *must* report the call to CallKit to avoid being terminated by iOS. This creates a race condition where the native incoming call screen briefly flashes on the screen before the app can execute a `CXEndCallAction` to dismiss it.



---

### **3. Transaction & State Synchronization Failures**

* **`CXErrorCodeRequestTransactionError` Code 4 (`unknownCallUUID`):**
* **Issue:** A commonly reported error on the [Apple Developer Forums](https://developer.apple.com/forums/tags/callkit). If the app attempts to update or end a call using a `UUID` before the system has fully finished registering the initial `CXStartCallAction` or `CXAnswerCallAction`, CallKit loses track of the transaction and rejects all subsequent commands.


* **Stuck "In-Call" System Banners:**
* **Issue:** If an app crashes or suffers an unhandled exception while a CallKit session is active, iOS sometimes fails to clear the native call state. The green "In-Call" indicator remains in the Status Bar/Dynamic Island indefinitely until the user hard-reboots the iPhone.



---

### **4. UI & Ecosystem Conflicts**

* **Cellular Call Interruption Priority:**
* **Issue:** When an incoming carrier cellular call arrives during an active VoIP CallKit session, iOS automatically prioritizes the cellular call. CallKit puts the VoIP call on hold, but frequently fails to send the proper `provider(_:didDeactivate:)` callback when the cellular call finishes, leaving the VoIP app frozen in a "Held" state.


* **Dual-SIM / Identity Mapping Glitches:**
* **Issue:** On Dual-SIM iPhones, initiating an outgoing call via CallKit often ignores the app's specified handle and forces iOS to prompt the user to choose a SIM line, breaking seamless programmatic dialing.



---

### **5. App Store & Regional Compliance**

* **App Store Rejections via the Chinese App Store:**
* **Issue:** The Chinese Ministry of Industry and Information Technology (MIIT) bans CallKit due to VoIP encryption regulations.
* **Impact:** Including the CallKit framework in an app binary submitted to the App Store in China results in an immediate, hard rejection by App Review. Developers are forced to build runtime geo-fencing checks or maintain separate build targets to strip CallKit dependencies entirely.

===

Signal’s codebase on [GitHub](https://github.com/signalapp/Signal-iOS) is widely studied by iOS developers who want to build production-grade VoIP apps. Examining how Signal handles CallKit reveals several critical implementation strategies:

**1. "Fake" Names to Protect Privacy**
To prevent CallKit from leaking sensitive contacts into the user's system call log or syncing them to iCloud, Signal obfuscates names at the CallKit boundary.

* **The Strategy:** Signal handles call parameters by passing generic placeholders like *"Signal User"* or localized strings to the `CXHandle` and `CXCallUpdate` objects.
* **The Result:** iOS gets the structural events it needs to display the native UI, but Apple's system logging tools never store actual contact names or phone numbers.

**2. Synchronous PushKit-to-CallKit Firing**
Apple enforces a zero-tolerance policy: when a PushKit payload hits the device, `reportNewIncomingCall(with:update:completion:)` must execute immediately.

* **The Strategy:** Signal doesn't wait to fetch full user profiles, verify cryptographic keys, or negotiate WebRTC session descriptors over the network before showing the call screen.
* **The Execution:** It reports the call to CallKit instantly with placeholder metadata, waken up the app process, and fetches the required payload *while* the native lock screen is ringing.

**3. Graceful De-escalation of Cancelled Calls**
One of the hardest CallKit edge cases is when a caller hangs up before the receiver answers.

* **The Problem:** If the push notification arrives, the app must report a call to CallKit—even if the caller already canceled.
* **The Strategy:** Signal tracks call tokens. If the system reports an incoming call that was canceled mid-flight, Signal immediately invokes `CXEndCallAction` in the same execution block. This satisfies Apple’s requirement to report the push, but dismisses the native UI before the phone rings visibly.

**4. Explicit Audio Session Handshakes (`AVAudioSession`)**
The most common CallKit failure point is the "silent mic" bug, which happens when the app tries to route WebRTC audio before iOS delegates permission.

* **The Strategy:** Signal never configures or activates its audio hardware on its own. It defers hardware control entirely to the `CXProviderDelegate` protocol method `provider(_:didActivate:)`.
* **The Execution:** Only after CallKit fires that explicit delegate callback does Signal spin up its WebRTC audio tracks, preventing broken audio channels.
