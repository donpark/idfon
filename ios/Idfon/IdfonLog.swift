import Foundation
import os

/// Native-app logging under one `os.Logger` subsystem (`app.idfon`), so app
/// output is filterable and level-tagged, and can be shipped to the idfon
/// telemetry collector (`log stream --predicate 'subsystem == "app.idfon"'`).
///
/// Category defaults to the source file (`#fileID`), so a predicate can narrow
/// to e.g. `category == "Idfon/Calls.swift"`. Values are logged `.public` to
/// match the visibility the previous `NSLog` calls had.
///
/// Note: the native apps do not export OTLP themselves (the daemon dylib stays
/// lean), so these lines do not carry the trace id; see docs/observability.md.
func idfonLog(_ message: String, file: String = #fileID) {
    logToIdfon(.info, message, file)
}

func idfonError(_ message: String, file: String = #fileID) {
    logToIdfon(.error, message, file)
}

private func logToIdfon(_ level: OSLogType, _ message: String, _ file: String) {
    Logger(subsystem: "app.idfon", category: file).log(level: level, "\(message, privacy: .public)")
    // Mirror to stderr like NSLog did: `devicectl … --console` and the e2e
    // scripts grep these markers there (pair-apple-channels.sh,
    // ios-device-test.sh, mac-e2e.sh); os.Logger alone never reaches them.
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    IdfonLogFile.append(message)
}

/// Per-run app log file — the rootless pull documented in
/// docs/troubleshooting.md (`devicectl device copy from --domain-type
/// appDataContainer --domain-identifier com.idfon.ios2 --source tmp/…`). One file
/// per process, named with the same pid as the in-process daemon's
/// `idfon-<pid>.log`, so one launch is one clean, pairable trace; stale logs
/// from earlier runs are removed at startup so the pull is unambiguous.
enum IdfonLogFile {
    private static let lock = NSLock()
    private static let handle: FileHandle? = {
        let dir = NSTemporaryDirectory()
        let me = ProcessInfo.processInfo.processIdentifier
        let fm = FileManager.default
        if let existing = try? fm.contentsOfDirectory(atPath: dir) {
            for name in existing
            where name.hasPrefix("idfon-") && name.hasSuffix(".log")
                && name != "idfon-\(me).log" && name != "idfon-app-\(me).log" {
                try? fm.removeItem(atPath: dir + name)
            }
        }
        let path = dir + "idfon-app-\(me).log"
        fm.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("\(stamp) \(message)\n".utf8)
        if let handle {
            try? handle.write(contentsOf: line)
            return
        }
        // Self-heal: the lazy create can fail at launch and the log file then
        // silently never appears (seen in the field — every E2E round ended
        // blind). Retry the creation per append.
        let path = NSTemporaryDirectory() + "idfon-app-\(ProcessInfo.processInfo.processIdentifier).log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let retry = FileHandle(forWritingAtPath: path) {
            _ = try? retry.seekToEnd()
            try? retry.write(contentsOf: line)
            try? retry.close()
        }
    }
}
