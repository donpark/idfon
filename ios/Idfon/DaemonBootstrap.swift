import Foundation

/// Paths for the in-process daemon.
///
/// Unix domain sockets are limited to ~104 bytes. Device sandbox paths fit
/// (~91 chars); no separate simulator path exists because the app is
/// device-only.
enum DaemonPaths {
    /// Durable profile: identity keys, peers, state. iOS may purge `tmp`
    /// whenever the app is not running, and a lost identity key changes the
    /// endpoint id — invalidating every subject-bound capability ticket (the
    /// app then sends as a new id the holders never admitted). The Mac app
    /// already keeps this in Application Support for the same reason.
    static var dataDir: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Idfon/daemon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateLegacyProfile(to: dir)
        return dir
    }

    static var socketPath: String {
        // No idfond subdir: the data-container path plus tmp/idfond/idfond.sock
        // exceeds SUN_LEN (104) on device — the flat tmp path fits. The socket
        // is recreated per launch, so `tmp` is fine for it.
        return FileManager.default.temporaryDirectory.appendingPathComponent("idfond.sock").path
    }

    /// One-time move of a legacy `tmp/idfond` profile into the durable
    /// location, so the daemon keeps its identity and peers instead of
    /// changing endpoint id (and invalidating paired tickets) on first run.
    private static func migrateLegacyProfile(to destination: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.appendingPathComponent("state.db").path) else { return }
        let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("idfond", isDirectory: true)
        guard legacy.path != destination.path,
              let entries = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
        else { return }
        var moved = 0
        for entry in entries where !["idfond.sock", "state.lock"].contains(entry.lastPathComponent) {
            if (try? fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))) != nil {
                moved += 1
            }
        }
        if moved > 0 {
            idfonLog("idfon: migrated daemon profile \(legacy.path) -> \(destination.path) (\(moved) items)")
        }
    }
}

/// Starts the daemon on a background thread. The daemon runs until process
/// exit (there is no stop path; see iroh-c-ffi/src/daemon.rs).
enum DaemonBootstrap {
    static func start() {
        let socket = DaemonPaths.socketPath
        let dataDir = DaemonPaths.dataDir.path
        // Rust media paths fall back to literal /tmp (absent in the iOS
        // sandbox): point NATIVE_SDK_APP_DATA_DIR at the durable profile so
        // video-frame.jpg / received.wav land somewhere writable.
        setenv("NATIVE_SDK_APP_DATA_DIR", dataDir, 1)
        // Bind only the active identity's endpoint; idle ones die on
        // background anyway, and `identity.use` binds on demand.
        setenv("IDFON_LAZY_IDENTITIES", "1", 1)
        // Enterprise relay config from settings, applied before the daemon binds.
        RelaySettings.applyToProcess()
        iroh_enable_tracing()
        let thread = Thread {
            let result = idfon_daemon_run(socket, dataDir, nil)
            if result != IDFON_DAEMON_OK {
                idfonLog("idfond exited with \(result)")
            }
        }
        thread.name = "idfond"
        thread.stackSize = 16 << 20 // Rust default main-thread stack is 8 MiB; match headroom
        thread.start()
    }
}
