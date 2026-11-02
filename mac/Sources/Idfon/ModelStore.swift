import Foundation

/// macOS-only on-device model storage.
///
/// All downloaded speech models live under `~/.idfon/models` (or
/// `$IDFON_HOME/models`) instead of FluidAudio's scattered defaults:
/// `~/Library/Application Support/FluidAudio` (legacy speech models). A
/// one-time best-effort migration moves models already downloaded there.
///
/// Not shared with iOS: on iOS `~` is the app sandbox, so the iOS app keeps
/// its per-container FluidAudio layout.

enum ModelStore {
    /// `$IDFON_HOME` if set, else `~/.idfon`, then `/models`.
    static var root: URL {
        let fileManager = FileManager.default
        let home: URL
        if let raw = ProcessInfo.processInfo.environment["IDFON_HOME"], !raw.isEmpty {
            home = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            home = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".idfon")
        }
        return home.appendingPathComponent("models", isDirectory: true)
    }

    /// A repo-rooted model directory, e.g. `…/models/parakeet-redux-coreml`.
    static func directory(named repo: String) -> URL {
        root.appendingPathComponent(repo, isDirectory: true)
    }

    /// Moves `source` to `destination` once, if the destination is absent and
    /// the source exists. Never overwrites; returns the destination on success.
    @discardableResult
    static func migrate(from source: URL, to destination: URL) -> URL? {
        let fileManager = FileManager.default
        guard destination != source,
              !fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: source.path) else { return nil }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

}
