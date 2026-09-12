# Peer-to-Peer Unified Communication Client

**UX & Architecture System Specification**

---

## 1. System Overview & Core Philosophy

This architecture eliminates the traditional boundary between mobile voice calling and text messaging. By replacing phone numbers with persistent **VoIP Identities** (e.g., handles, usernames, SIP endpoints), the system merges telephony and messaging into a single, person-centric interface.

### Key Principles

* **Person-First Navigation:** Interactions center on the contact, not the app or communication medium.
* **Peer-to-Peer Architecture:** Active VoIP calls double as direct P2P data channels for media streaming and file transfers, eliminating cloud storage overhead and mid-call context switching.
* **Contextual State Machines:** Controls dynamically morph based on connection status, media toggles, and user intent, eliminating legacy remnants like numeric DTMF keypads.
* **Persistent Activity Overlay:** Live activities (calls, transfers, streams) are daemon-backed and never terminate when the user navigates away. The **Live Activity Bar** renders them from a window-level overlay visible on every screen and above modals.

### Terminology

| Component | Role |
| --- | --- |
| **Live Activity Bar** | The persistent overlay surface: activity states, in-call controls, and (expanded) tray rows. |
| **Session Tray** | Expanded rows of the Live Activity Bar showing per-activity progress (transfers, streams). Not a separate screen component. |
| **Compact Pill** | The Bar's collapsed density, shown when the user is outside the activity's owning thread. |

---

## 2. Core Layout & Navigation Structure

The interface relies on a single persistent thread per contact, anchored by the **Live Activity Bar** (a window-level overlay, see §6) for active session controls and a **Bottom Message Input Bar** for text and media payloads.

```
+-----------------------------------------------------------------------+
| [<] @janedoe                        [ Mic ON ]  [ Cam OFF ]   [ End ] |  <-- Live Activity Bar (expanded, own thread)
| --------------------------------------------------------------------- |
| > Transferring "Archive.zip" (42%) - 12MB/s                  [Cancel] |  <-- Active Session Tray
+-----------------------------------------------------------------------+
|                                                                       |
|  @janedoe                                                             |
|  [Voice Call Started - 10:15 AM]                                      |
|                                                                       |
|  Hey, can you take a look at this build?                              |
|  10:16 AM                                                             |
|                                                                       |
|  +-----------------------------------------------------------------+  |
|  | [ + ]  Type a message...                                  [ -> ]|  |  <-- Bottom Input Bar
|  +-----------------------------------------------------------------+  |
+-----------------------------------------------------------------------+

```

---

## 3. Live Activity Bar State Logic

The Bar replaces standard dialer screens with an inline control bar that evolves through three primary operational states. (Incoming-call handling is per-connection — CallKit or the Bar, with the Bar as the interim default until CallKit lands; see §6, Incoming-call handling. Outgoing-pending presentation remains open.)

### State 1: Idle (Not in Call)

```
+-----------------------------------------------------------------------+
|  [<] @janedoe                       [ Mic OFF ]  [ Cam OFF ]  [ Ping ]|
+-----------------------------------------------------------------------+

```

* **Default Condition:** Both `Mic` and `Cam` are toggled `OFF`.
* **Primary Action:** `[Ping]`. Tapping sends an ephemeral, low-priority "Free to talk?" notification to the recipient’s chat thread without causing the receiving device to ring loudly.

### State 2: Pre-Call Staging

```
+-----------------------------------------------------------------------+
|  [<] @janedoe                       [ Mic ON  ]  [ Cam OFF ]  [ Call ]|
+-----------------------------------------------------------------------+

```

* **Trigger:** Enabling either `[Mic ON]` or `[Cam ON]` staging toggles.
* **Primary Action:** Instantly transforms `[Ping]` into `[Call]`.
* **Staged stream set:** The staging toggles choose which outgoing streams the call carries — `Mic` only (audio call), `Cam` only (video-only: camera with no audio), or both (audio + video). Both off stays Idle (`[Ping]`).
* **Benefit:** Allows users to establish their audio/video entry states *before* initiating connection, preventing accidental background-noise intros.

### State 3: Active Call

```
+-----------------------------------------------------------------------+
|  [<] @janedoe                       [ Mic ON  ]  [ Cam ON  ]  [ End  ]|
+-----------------------------------------------------------------------+

```

* **Active Elements:** Displays live call timer, active audio/video toggles, and a prominent red `[End]` button.
* **Live In-Call Toggling:** `Mic` and `Cam` independently gate whether each outgoing stream is **sent** or **withheld** — mute/unmute and camera on/off — without tearing down the VoIP session. This is send/no-send gating, **not** track attach/detach: the session and its negotiation stay intact. A muted mic sends silence (capture stays open, unmute is instant); a disabled camera sends no frames (the peer holds the last frame). A call can only toggle streams it was started with: turning the camera on during an audio-only call, or vice versa, would require renegotiation and is out of scope.

---

## 4. Session Tray (File Transfers & Streaming)

The Session Tray is the Live Activity Bar's expanded content: collapsible rows that appear directly beneath the main Bar when data transactions occur. Transfers do not require an active call (the blob layer is ticket-based), so tray rows are valid in every Bar state — an Idle-state tray design is still open.

> **Prior art note:** urgent activities (calls) get overlays nothing covers (system call banner, WhatsApp/Telegram call bubbles); passive activities (media, transfers) get docked surfaces modals may cover (Spotify mini-player). idfon uses one overlay: guaranteed visibility exists for the call; tray rows ride along for free.

```
STATE A: DATA PAYLOAD (P2P FILE TRANSFER)
+-----------------------------------------------------------------------+
|  [<] @janedoe                       [ Mic ON ]  [ Cam OFF ]   [ End ] |
|  -------------------------------------------------------------------  |
|  > Transferring "Archive.zip" (42%) - 12MB/s                [Cancel]  |
+-----------------------------------------------------------------------+

STATE B: CONTINUOUS MEDIA (STREAMING)
+-----------------------------------------------------------------------+
|  [<] @janedoe                       [ Mic ON ]  [ Cam OFF ]   [ End ] |
|  -------------------------------------------------------------------  |
|  > Streaming "Demo_Track.mp3" (01:45 / 03:20)                 [ Stop ]|
+-----------------------------------------------------------------------+

```

### Action Label & Behavior Matrix

| Session Type | Progress Indicator | Terminal Action | Action Result |
| --- | --- | --- | --- |
| **File Transfer** | Byte percentage (`42%`), Transfer speed (`12 MB/s`) | `[Cancel]` | Aborts P2P chunk transfer; purges partial temporary files on receiver device. |
| **Media Stream** | Playhead time (`01:45 / 03:20`), Play/Pause | `[ Stop ]` | Tears down the active WebRTC media feed; closes synchronized stream player in chat feed. |

---

## 5. File Selection & Intent Modal Flow

When tapping the attachment button `[ + ]` in the bottom input bar while a call is active, the system executes intent routing based on file type.

```
+-----------------------------------------------------------------------+
|                         Handle Large Media                            |
|                                                                       |
|  "Presentation_Demo.mp4" (250 MB)                                    |
|                                                                       |
|  [ Stream Content ]             [ Send File ]                         |
|  Plays video live in-call       Transfers full file directly          |
|  (Zero local storage used)      (Saved to recipient's device)         |
|                                                                       |
|                                 [ Cancel ]                            |
+-----------------------------------------------------------------------+

```

1. **Non-Streamable Files (`.zip`, `.pdf`, `.docx`):** Bypasses modal selection. Initiates a direct P2P background file transfer tracked via the Live Activity Bar's Session Tray.
2. **Streamable Files (`.mp4`, `.mkv`, `.mp3`, `.flac`):** Prompts the **Intent Modal**:
* **`[ Stream Content ]`:** Mounts the file as an active live audio/video track over the call. Streams in real time to the recipient's inline chat player without consuming local disk space on their end.
* **`[ Send File ]`:** Queues a direct P2P binary upload to the recipient's local device storage.

---

## 6. Window-Level Overlay & Cross-Screen Persistence

Leaving a screen never terminates an activity: calls, transfers, and streams continue regardless of navigation. The Live Activity Bar is therefore **not embedded in any screen** — it is a floating overlay above all navigation and modals.

### Why not per-screen embedding

A subview in a presenting screen cannot appear above a presented modal (UIKit presentation semantics), so embedded bars vanish exactly during the Intent Modal, ringing screen, and other focused tasks. Per-screen hosting also means N bar instances syncing one state, transition jank (timer/progress jumping during push/pop), and a standing regression class of "bar missing from a forgotten screen." Every major app that does persistent activity (FaceTime, WhatsApp, Telegram, Messenger) uses a floating overlay; none leave activity chrome embedded in a host screen.

### iOS implementation constraints

* **One `UIWindow` per `UIWindowScene`**, created at scene launch and held by a strong scene-level reference — an unreferenced window silently deallocates.
* **`windowLevel` between content and keyboard/alerts:** threads, tab screens, and sheets slide beneath the Bar; the keyboard correctly covers it (text input lives below the Bar, so this is desired behavior).
* **Pass-through hit-testing:** the overlay window subclass returns `nil` from `hitTest` outside the Bar frame — the Bar floats while the app stays fully interactive.
* **Safe area:** the Bar reads the scene's safe-area insets directly; no per-screen inset coordination.
* **Dock position: top, below the navigation bar — never over nav chrome.** Precedent: WhatsApp/Telegram "return to call" bars. (FaceTime/Zoom/Meet use system PiP; Discord/Slack use a bottom presence bar — the bottom pattern does not apply here.) The Bar is inserted below navigation chrome and content shifts down to make room, so it displaces content rather than floating over it. This supersedes the earlier "keyboard covers it" remark, which described a bottom presence bar.
* **Interrupts present above the overlay:** an incoming call's ringing screen uses its own higher-level window/presentation — the same layering as the system call banner appearing over a PiP bubble.

### Incoming-call handling: two modes

How an arriving call is presented is a per-connection decision, not a global app setting. Each connection carries an incoming-call mode:

| Mode | Presentation | Notes |
| --- | --- | --- |
| **CallKit** | System call UI (`CXProvider`), presented by iOS | Requires PushKit VoIP push; see `docs/callkit-integration.md` for the APNs/push constraints and pitfalls |
| **Live Activity Bar** | In-app ringing surface, presented by the Bar's own higher-level window above the overlay | No lock-screen UI; the app must own `AVAudioSession` |

The split follows the relationship, not the transport:

* **CallKit is for reaching people who aren't here.** Connections that are offline or contacted infrequently need a ring that works when the app isn't open — the system surface reaches them on the lock screen and behaves like a phone call. Loud on purpose; the cost is PushKit/APNs and the system consuming the ring.
* **The Bar is for people who are already here.** Agents and tight teams are continuously online and working together; a full-screen ring is disruptive and redundant when the app is already in front of them. They need a low-friction, in-app incoming surface that doesn't hijack the screen — the same reasoning behind Discord/Slack huddles and the non-CallKit auto-connect path in `docs/callkit-integration.md`.

So the mode is chosen when a connection is set up, by how reachable its person is expected to be — not by what kind of call is being placed.

Both modes funnel into the **same call state machine** — the mode only selects who owns incoming-ring presentation. The routing point sits in front of `VideoCall`/`CallSession` `handleEnvelope`, keyed by the sending connection's configuration.

* **Interim default: Live Activity Bar.** Until CallKit integration works, every connection uses the Bar path. This is a temporary default, not a fallback policy — no connection should silently switch modes at runtime.
* **CallKit path must not double-present.** When CallKit owns the ring, the Bar stays out of the incoming state entirely (no second ringing surface) and reflects only the answered/active call.
* **An unreachable or disabled CallKit mode must not affect the Bar path.** The two are independent; the Bar is fully functional without PushKit, APNs, or VoIP entitlements.

Incoming surface is **inline Answer/Decline in the Bar** (decided, implemented — no fullscreen
ringing screen on the Bar path). Outgoing-pending presentation remains open (currently
`Calling…` + End).

### Two visual densities, one state machine

* **Expanded (owning thread):** contact header, staging/active toggles, tray rows — as specified in §2–§4.
* **Compact pill (any other screen):** e.g. `● 03:42 @janedoe — 1 transfer` — tap jumps to the owning thread.
* Activities from other contacts render as compact pills while the current thread's own Bar state renders inline (e.g., in a call with Jane, Bob's thread shows its Idle/Staging chrome plus Jane's pill).
* **End from the compact pill requires confirmation** — a tap that spans screens must not silently end a call. (Draggable-bubble physics à la WhatsApp/FaceTime is optional polish; a docked pill ships fine.)
