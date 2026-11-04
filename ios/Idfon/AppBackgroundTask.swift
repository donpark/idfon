import UIKit

/// Call teardown that survives suspension: a call that ends while the app is
/// backgrounded (screen locked) must still send its stop envelope and finish
/// `media_live_stop` before iOS suspends the process — otherwise the peer's
/// call lingers until the transport times out (and the engine state left
/// behind confuses `recoverStaleCall`).
enum AppBackgroundTask {
    /// Runs `body` on a detached task inside a system background task.
    /// Callable from any context; the UIKit calls hop to main.
    static func run(_ body: @escaping @Sendable () async -> Void) {
        Task { @MainActor in
            let task = UIApplication.shared.beginBackgroundTask(withName: "idfon.call-teardown")
            Task.detached(priority: .userInitiated) {
                await body()
                await MainActor.run { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }
}
