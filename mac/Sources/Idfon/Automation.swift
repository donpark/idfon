import Foundation

/// Launch-argument automation for the on-mac flows that can't be checked
/// headlessly (see scripts/mac-e2e.sh).
///
/// It drives the *real* code path — the same `ChatViewController.sendFile` the
/// attachment panel reaches — so a run exercises the actual wiring rather than
/// a parallel copy. Markers go to stderr and os_log with a stable prefix the
/// harness asserts on.
enum Automation {
    /// `-sendfile <peer-ref> <absolute-path>`: select the peer's thread and send
    /// the named file.
    static let pendingSendFile: (peer: String, path: String)? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-sendfile"), args.count > index + 2 else { return nil }
        return (args[index + 1], args[index + 2])
    }()

    /// Writes a harness-visible marker. `stderr` is unbuffered, so it lands
    /// immediately; the `NSLog` is for the unified log trail.
    static func mark(_ message: String) {
        FileHandle.standardError.write(Data("idfon-auto: \(message)\n".utf8))
        NSLog("idfon-auto: \(message)")
    }
}
