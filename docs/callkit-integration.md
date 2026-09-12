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
* `ios/Idfon/IncomingCallRouter.swift` is the single routing point: an incoming invite
  resolves the **sending connection's** mode, then either hands it to the CallKit presenter
  or to the Bar path (`LiveCall` + `VideoCall`).
* `CallKitIncomingPresenter.isAvailable` is `false` — the one gate that flips when CallKit
  integration lands. Until then a connection configured for `call_kit` is presented in the
  Bar and the deferral is logged once per peer (explicit, never a silent mode switch). The
  per-chat "Incoming calls" menu shows CallKit disabled with "Not available yet", so a
  connection cannot be configured into a mode that cannot be served.
* CallKit is iOS-only: macOS has no `CXProvider`, so mac always presents in-app and needs no
  routing seam.

Not implemented: `CXProvider`/`CXProviderDelegate`, PushKit VoIP registration and token
handling, the APNs payload split, and audio-session handoff to CallKit. The I/O notes below
still apply to that work.

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
