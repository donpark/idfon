Apple’s **CallKit** framework and **iroh** (the peer-to-peer networking library built by n0) can be integrated, but they operate at completely different layers of the software stack:

* **CallKit** handles the **iOS system UI** and phone integration (presenting native incoming/outgoing call screens, syncing with system call history, managing mute/hold states, and respecting system behaviors like Do Not Disturb).
* **iroh** handles the **P2P transport layer** (establishing peer-to-peer connections using QUIC, hole punching through NATs, end-to-end encryption, and low-latency audio stream delivery).

Because they perform separate roles, they can be wired together to build a native iOS VoIP application.

---

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
