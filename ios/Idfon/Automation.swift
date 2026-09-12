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

    /// Writes a harness-visible marker. `stderr` is unbuffered, so it lands in
    /// `devicectl ... --console` immediately; the `NSLog` is for the device
    /// console / sysdiagnose trail.
    static func mark(_ message: String) {
        FileHandle.standardError.write(Data("idfon-auto: \(message)\n".utf8))
        NSLog("idfon-auto: \(message)")
    }
}
