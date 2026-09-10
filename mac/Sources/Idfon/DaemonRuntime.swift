import Foundation
import AppKit
import CIdfon

/// Mac daemon runtime: the daemon is a sibling subprocess (unlike iOS, which
/// runs it in-process). Socket/data-dir come from the Rust single source of
/// truth (idfon_client_socket_path), so the CLI, native GUI, and this app
/// share one default profile at /tmp/idfon.
enum DaemonRuntime {
    static let socketPath: String = {
        var buffer = [UInt8](repeating: 0, count: 256)
        let len = idfon_client_socket_path(nil, &buffer, buffer.count)
        let path = len > 0 ? String(cString: buffer) : "/tmp/idfon/idfond.sock"
        return path
    }()

    static var dataDir: String {
        let url = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
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
            NSLog("idfon: no idfond binary found (looked in bundle dir, ../target/release, /usr/local/bin)")
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
        do {
            try process.run()
            NSLog("idfon: launched idfond pid=\(process.processIdentifier) socket=\(socket)")
        } catch {
            NSLog("idfon: idfond spawn failed: \(error.localizedDescription)")
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