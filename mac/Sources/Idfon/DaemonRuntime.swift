import Foundation
import AppKit
import CIdfon

/// Mac daemon runtime: the daemon is a sibling subprocess (unlike iOS, which
/// runs it in-process). The socket comes from the Rust single source of truth
/// (`idfon_client_socket_path`, `/tmp/idfon/idfond.sock`) so the CLI, native
/// GUI, and this app all share one profile; the *data dir* is durable
/// (Application Support), because `/tmp` is cleared on reboot and would take
/// the daemon's identity — and every subject-bound ticket — with it.
enum DaemonRuntime {
    static let socketPath: String = {
        var buffer = [UInt8](repeating: 0, count: 256)
        let len = idfon_client_socket_path(nil, &buffer, buffer.count)
        let path = len > 0 ? String(cString: buffer) : "/tmp/idfon/idfond.sock"
        return path
    }()

    /// Durable profile directory for the daemon (identity, peers, state).
    static var dataDir: String {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Idfon/daemon", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        migrateLegacyProfile(to: support)
        return support.path
    }

    /// Per-conversation media directory (recordings, fetched blobs, video
    /// frames). Must be absolute: the FFI `create_dir_all`s this path directly,
    /// so a bare peer id would otherwise become a directory in the app's cwd.
    static func mediaDir(_ key: String) -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Idfon/media", isDirectory: true)
        let safe = key.replacingOccurrences(of: "/", with: "_")
        let dir = base.appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// One-time move of a legacy `/tmp/idfon` profile into the durable
    /// location, so the daemon keeps its identity and peers instead of
    /// starting from scratch on first run of this build.
    private static func migrateLegacyProfile(to destination: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.appendingPathComponent("state.db").path) else { return }
        let legacy = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        guard legacy.path != destination.path,
              let entries = try? fm.contentsOfDirectory(at: legacy,
                                                        includingPropertiesForKeys: nil) else { return }
        var moved = 0
        for entry in entries where !["idfond.sock", "state.lock"].contains(entry.lastPathComponent) {
            if (try? fm.copyItem(at: entry,
                                 to: destination.appendingPathComponent(entry.lastPathComponent))) != nil {
                moved += 1
            }
        }
        if moved > 0 {
            idfonLog("idfon: migrated daemon profile \(legacy.path) -> \(destination.path) (\(moved) items)")
        }
    }

    private static var launched = false

    /// One-time env setup (Rust media paths + tracing).
    static func configure() {
        let appData = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Idfon", isDirectory: true)
        try? FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        setenv("NATIVE_SDK_APP_DATA_DIR", appData.path, 1)
        iroh_enable_tracing()
    }

    /// Spawns the idfond subprocess once. Cheap no-op when a daemon is
    /// already listening (CLI or the native GUI shares the same socket) —
    /// the extra child fails to bind and exits; the launcher just retries.
    static func launchIfNeeded() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !launched else { return }
        launched = true
        let socket = socketPath
        let data = dataDir
        guard let idfond = locateDaemon() else {
            idfonLog("idfon: no idfond binary found (looked in bundle dir, ../target/release, /usr/local/bin)")
            return
        }
        let log = FileHandle(forWritingAtPath: "/tmp/idfond-auto.log") ?? {
            FileManager.default.createFile(atPath: "/tmp/idfond-auto.log", contents: nil)
            return FileHandle(forWritingAtPath: "/tmp/idfond-auto.log")!
        }()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: idfond)
        process.arguments = ["--socket", socket, "--data-dir", data]
        process.standardOutput = log
        process.standardError = log
        // Enterprise relay config from settings (runtime, not compiled in).
        let relayEnv = RelaySettings.environment()
        if !relayEnv.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(relayEnv) { _, new in new }
        }
        do {
            try process.run()
            idfonLog("idfon: launched idfond pid=\(process.processIdentifier) socket=\(socket)")
        } catch {
            idfonError("idfon: idfond spawn failed: \(error.localizedDescription)")
        }
        // Deliberately keep the child running when the app quits: idfond is a
        // shared service (the GUI shell does the same) and idles out on its own.
    }

    private static func locateDaemon() -> String? {
        var candidates: [String] = []
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(execDir.appendingPathComponent("idfond").path)
        }
        candidates.append("../target/release/idfond") // swift run from mac/
        candidates.append("/usr/local/bin/idfond")
        if let env = ProcessInfo.processInfo.environment["IDFOND_PATH"] {
            candidates.insert(env, at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}