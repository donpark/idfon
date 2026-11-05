import Foundation

/// Launch-argument automation for the on-device flows that can't run
/// headlessly (see scripts/ios-device-test.sh).
///
/// It drives the *real* code path — the same `ChatViewController.sendFile` a
/// tap on the attachment picker reaches — so a run exercises the actual
/// wiring, not a parallel copy. Markers go to stderr and os_log with a stable
/// prefix the harness asserts on.
enum Automation {
    /// `-sendfile <peer-ref> <fileName>`: open the peer's thread and send the
    /// named file from the app's Documents directory.
    static let pendingSendFile: (peer: String, file: String)? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-sendfile"), args.count > index + 2 else { return nil }
        return (args[index + 1], args[index + 2])
    }()

    /// `-healthcheck <peer-ref> [delaySeconds]`: open the thread and post the
    /// card a typed `/health-check` reaches — the real path, no taps.
    static let pendingHealthCheck: (peer: String, delay: Double)? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-healthcheck"), args.count > index + 1 else { return nil }
        let delay = args.count > index + 2 ? (Double(args[index + 2]) ?? 0) : 0
        return (args[index + 1], delay)
    }()

    /// Writes a harness-visible marker. `idfonLog` mirrors to stderr (unbuffered,
    /// so it lands in `devicectl … --console` immediately) and to os_log.
    static func mark(_ message: String) {
        idfonLog("idfon-auto: \(message)")
    }
}
