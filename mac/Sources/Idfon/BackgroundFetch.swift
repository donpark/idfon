import Foundation

/// Pure bookkeeping helpers for `EdgeClient`'s background edge fetches
/// (`docs/idfon-edge.md`, P4). Foundation-only so the host check
/// `ios/Checks/JSONRenderCheck` can exercise them.
enum BackgroundFetch {
    /// Drops pending-task entries older than `ttl`, so a task that never
    /// completes cannot pin its mapping (or its staged file) forever. An entry
    /// without a timestamp is kept: an upgrade must not discard in-flight work.
    static func pruned(
        _ pending: [[String: String]],
        now: Date,
        ttl: TimeInterval
    ) -> [[String: String]] {
        pending.filter { entry in
            guard let at = entry["at"].flatMap(TimeInterval.init) else { return true }
            return now.timeIntervalSince1970 - at < ttl
        }
    }

    /// A staged inbox file is stale when it is at least `ttl` old. A missing
    /// modification date is not treated as stale.
    static func isStale(modified: Date?, now: Date, ttl: TimeInterval) -> Bool {
        guard let modified else { return false }
        return now.timeIntervalSince(modified) >= ttl
    }
}
