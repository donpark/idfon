# macOS App Architecture

The macOS app (`mac/Sources/Idfon/`, ~3.3K lines Swift) is a SwiftPM-built AppKit app.
Unlike iOS (in-process daemon thread), **the daemon is a sibling subprocess**.

```text
mac/
├── Package.swift              # SwiftPM package (Idfon executable)
├── Sources/Idfon/
│   ├── IdfonApp.swift         # @main; AppDelegate, AppModel (identity mgmt),
│   │                          #   DetailContainerViewController, Placeholder
│   ├── SidebarViewController.swift  # peer list + AudioSettingsViewController
│   ├── ChatViewController.swift     # chat table + composer (text/memo/live call)
│   ├── ChatStore.swift        # polling event loop: waitMessages → updates
│   ├── DaemonRuntime.swift    # spawns idfond subprocess (bundle dir,
│   │                          #   ../target/release, /usr/local/bin); survives app quit
│   ├── DaemonClient.swift     # JSON IPC request/response over Unix socket
│   ├── DaemonClient+Methods.swift   # status/peers/sendText/waitMessages/events
│   ├── Calls.swift            # LiveCall (audio) + VideoCall state machines
│   ├── CameraPusher.swift     # AVCapture → FFI push_frame (1280x720 landscape)
│   ├── VoiceMemo.swift        # AVAudioRecorder memo + amplitudes
│   ├── WaveformView.swift     # mic-level visualization
│   ├── BlobTransfer.swift     # put/fetch blobs (memos & photos)
│   └── Models.swift           # Peer / Message / Event
└── Vendor/                    # libiroh_c_ffi (Rust, gitignored)
```

```mermaid
flowchart TD
    subgraph AppKit["AppKit UI layer (main thread)"]
        SB[SidebarViewController<br/>+ AudioSettings] --> CV[ChatViewController]
        CV --> AM[AppModel<br/>identity management]
    end
    subgraph Services["App services"]
        CV --> CS[ChatStore<br/>event poll loop]
        CV --> CALLS[Calls.swift<br/>LiveCall + VideoCall]
        CV --> CAMP[CameraPusher<br/>AVCapture frames]
        CV --> WM[VoiceMemo]
        CS & CALLS & WM --> DC[DaemonClient<br/>+ BlobTransfer]
    end
    subgraph Runtime["Runtime"]
        DR[DaemonRuntime<br/>spawns idfond subprocess] --> D[idfond<br/>sibling process]
        DC -->|Unix socket JSON IPC| D
        CAMP -->|media_video_push_frame| FFI[libiroh_c_ffi<br/>direct C calls]
        CALLS --> FFI
        D --> IROH[iroh-net / moq]
    end
```

Key facts:

- **Daemon is a sibling subprocess**: `DaemonRuntime.launchIfNeeded()` locates
  `idfond` (bundle dir → `../target/release` → `/usr/local/bin`) and spawns it,
  logging to `/tmp/idfond-auto.log`. The child deliberately outlives the app —
  `idfond` is a system-wide service. Shared socket: `/tmp/idfon/idfond.sock`
  (see `crates/idfond`).
- **Same layering as iOS**: `DaemonClient` JSON IPC for chat/events, direct C media
  calls for the call/camera path (video uses landscape 1280x720 vs iOS portrait).
- **CLI interop**: the mac app and the `idfon` CLI share the same daemon/socket, so
  chats are visible from both.

See also: [video-media.md](video-media.md), [audio-media.md](audio-media.md),
[ios-architecture.md](ios-architecture.md) for the in-process-daemon variant.
