import Foundation

/// Paths for the in-process daemon.
///
/// Unix domain sockets are limited to ~104 bytes. Device sandbox paths fit
/// (~91 chars), but simulator container paths are ~180 chars, so the
/// simulator uses a short /tmp path instead (simulator apps share the host
/// /tmp; one booted sim at a time per socket name).
enum DaemonPaths {
    static var dataDir: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idfond", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var socketPath: String {
        #if targetEnvironment(simulator)
        return "/tmp/idfon-ios.sock"
        #else
        return dataDir.appendingPathComponent("idfond.sock").path
        #endif
    }
}

/// Starts the daemon on a background thread. The daemon runs until process
/// exit (there is no stop path; see iroh-c-ffi/src/daemon.rs).
enum DaemonBootstrap {
    static func start() {
        let socket = DaemonPaths.socketPath
        let dataDir = DaemonPaths.dataDir.path
        let thread = Thread {
            let result = idfon_daemon_run(socket, dataDir, nil)
            if result != IDFON_DAEMON_OK {
                NSLog("idfond exited with \(result)")
            }
        }
        thread.name = "idfond"
        thread.stackSize = 16 << 20 // Rust default main-thread stack is 8 MiB; match headroom
        thread.start()
    }
}
