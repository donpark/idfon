# iOS App Architecture

The iOS app (`ios/Idfon/`, ~3.8K lines Swift) is a UIKit app with programmatic UI that
talks to an **in-process Rust daemon** (`idfond`, via the `libiroh_c_ffi.a` static lib).

```text
ios/
├── Idfon/                    # Swift app (UIKit, programmatic UI)
│   ├── AppDelegate.swift     # app lifecycle, starts daemon + audio session, launch-arg automation
│   ├── SceneDelegate.swift   # window, 3-tab root, Live Activity Bar overlay wiring
│   ├── AppNavigationController.swift # per-tab nav clearance + content-shift for the Bar
│   ├── PeerListViewController.swift  # Contacts tab: searchable peer list → chat
│   ├── PlaceholderViewController.swift # empty-state tab (Favorites, Recents)
│   ├── ChatViewController.swift      # chat table + composer (text/record/review)
│   │                         #   + inline live-video pane, incoming-call-mode menu
│   ├── CallViewController.swift      # fullscreen video surface (presented on demand, not on ring)
│   ├── LiveActivityBar.swift # the Bar surface + value-type model (expanded / compact pill)
│   ├── OverlayWindow.swift   # window-level Bar host (pass-through hitTest)
│   ├── LiveActivityController.swift  # maps call state → Bar models, routes Bar intents
│   ├── IncomingCallRouter.swift      # per-connection Bar-vs-CallKit incoming routing seam
│   ├── ChatStore.swift       # polling event loop: waitMessages → notifications
│   ├── Models.swift          # Peer / Message / Event / IncomingCallMode
│   ├── VideoCall.swift       # video-call state machine (dial/answer/route events)
│   ├── LiveCall.swift        # audio-call state machine + LiveCallHarness (WAV test path)
│   ├── CameraPusher.swift    # AVCapture → FFI push_frame (BGRA 720x1280)
│   ├── VoiceMemo.swift       # AVAudioRecorder memo + waveform amplitudes
│   ├── LiveWaveformView.swift# mic-level visualization
│   ├── BlobTransfer.swift    # put/fetch blobs (memo & photo exchange)
│   ├── DaemonClient.swift    # JSON IPC request/response (5s timeout)
│   ├── DaemonClient+Methods.swift    # status/peers/sendText/waitMessages/events/call-mode
│   ├── DaemonBootstrap.swift # spawns idfond on background thread, socket paths
│   └── Idfon-Bridging.h      # C ABI surface (daemon_run, client_request, media_*)
├── Checks/                   # host-run checks via Mac Catalyst (not in the Xcode target)
└── Vendor/                   # libiroh_c_ffi.a static lib (Rust, gitignored)
```

The app's central UI is the **Live Activity Bar** (`docs/ui-design-notes.md`,
`docs/live-activity-bar-layout.md`): one window-level overlay that docks below nav
chrome, persists across navigation, gates the outgoing audio/video streams, and owns
in-app incoming calls.

```mermaid
flowchart TD
    subgraph Swift["Swift UI layer (main thread)"]
        TB[UITabBarController<br/>Favorites · Recents · Contacts] --> PL[PeerListViewController]
        PL --> CV[ChatViewController]
        CV --> CVC[CallViewController]
        CV --> WM[VoiceMemo]
        CV --> CAMP[CameraPusher<br/>AVCapture frames]
        CV --> CS[ChatStore<br/>event poll loop]
        CS -->|invite envelopes| R[IncomingCallRouter<br/>per-connection mode]
        R -->|Bar| LC[LiveCall<br/>audio machine]
        R -->|Bar| VC[VideoCall<br/>video machine]
        R -->|CallKit| CK[CallKitIncomingPresenter<br/>stub · isAvailable=false]
        LC & VC --> LAC[LiveActivityController]
        LAC --> OW[OverlayWindow → LiveActivityBar]
        LAC -.->|clearance, content inset, per tab| NAV[AppNavigationController ×3]
    end
    subgraph Services["App services"]
        CS --> DC[DaemonClient<br/>+ Methods, BlobTransfer]
        LC & VC --> FFI1[media_live_start(audio,video)<br/>set_audio/video_enabled]
        CAMP --> FFI2[media_video_push_frame]
        WM --> FFI3[blob put/fetch]
        CS --> FFI4[idfon_client_request]
    end
    subgraph Rust["Rust static lib (libiroh_c_ffi.a)"]
        FFI1 & FFI2 & FFI3 & FFI4 --> D[idfond daemon<br/>in-process thread]
        D --> IROH[iroh-net / moq<br/>live audio + video + blobs]
    end
```

Key facts:

- **Daemon is in-process**: `AppDelegate` → `DaemonBootstrap.start()` runs
  `idfon_daemon_run` on a background `Thread` (16MB stack); it lives until process
  exit. No separate daemon binary. A Rust change therefore means rebuilding the
  vendored `ios/Vendor/{device,sim}` libs.
- **One IPC channel, two usages**: JSON requests/responses (`idfon_client_request`
  over Unix socket, each call its own connection) for chat/events/peers, and direct C
  media functions that bypass IPC entirely (zero-copy frame push).
- **Events are polled**: `ChatStore` long-polls `waitMessages` (30s). Invite
  envelopes go through `IncomingCallRouter` (per-connection Bar-vs-CallKit mode);
  `call_started`/`call_stopped` go direct to both machines, since the mode governs
  presentation, not teardown.
- **The Bar is a window-level overlay** (`OverlayWindow`, one per scene, held by
  `LiveActivityController`): `windowLevel` above content but below the keyboard, and
  `hitTest` passes through outside the Bar. The controller is the
  `UITabBarControllerDelegate`: it reads clearance from the selected tab's
  `AppNavigationController`, fans the Bar's content inset out to **every** tab's nav, and
  re-anchors on tab switch (a call whose thread is behind another tab renders as a pill).
- **Calls are two machines, one Bar model**: `LiveCall` (audio) and `VideoCall`
  (video/video-only) are disjoint — separated by the invite's `media` value — and
  `LiveActivityController` renders whichever is non-idle. Mic/cam buttons gate
  whether each published stream is *sent*; the stream set is chosen at dial time.
- **Sim vs device socket path**: sim uses `/tmp/idfon-ios.sock` (sandbox paths exceed
  the 104-byte `SUN_LEN`), device uses flat tmp path.
- **On-device automation**: `ios/device.sh` builds/installs/launches on a physical
  iPhone via `devicectl`; launch arguments drive no-tap flows (`-dial`, `-answer`,
  `-videodial`, `-camprobe`, `-memo`, `-pair`). `-sendfile <peer> <fileName>`
  (`Automation.swift`) opens the thread and calls the same `sendFile` the attachment
  picker reaches; `scripts/ios-device-test.sh` stages a file in the app container and
  asserts the `idfon tray:` / `idfon file:` markers. Purely visual behavior (tabs, Bar
  docking, the Files picker) stays manual — there is no XCUITest target.

See also: [ui-design-notes.md](ui-design-notes.md) (UX spec),
[live-activity-bar-layout.md](live-activity-bar-layout.md) (Bar layout + integration
contract), [callkit-integration.md](callkit-integration.md) (CallKit notes),
[protocol.md](protocol.md) (IPC), [audio-media.md](audio-media.md),
[video-media.md](video-media.md).
