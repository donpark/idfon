import Foundation

/// macOS-only on-device model storage.
///
/// All downloaded speech models live under `~/.idfon/models` (or
/// `$IDFON_HOME/models`) instead of FluidAudio's scattered defaults:
/// `~/Library/Application Support/FluidAudio` (Parakeet ASR),
/// `~/.cache/fluidaudio` (Kokoro TTS), and
/// `~/Library/Caches/idfon/speech-packs` (direct Kokoro packs). A one-time
/// best-effort migration moves models already downloaded at those locations.
///
/// Not shared with iOS: on iOS `~` is the app sandbox, so the iOS app keeps
/// its per-container FluidAudio layout.
///
/// Known ceiling: FluidAudio's shared English G2P assets are pinned to
/// `~/.cache/fluidaudio/Models/kokoro` (a singleton hardcodes that path), so
/// they do not follow the move. They are small compared to the model chain.
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

    /// Kokoro ANE models root. FluidAudio appends the repo folder, so the
    /// chain lands at `…/kokoro/kokoro-82m-coreml/ANE/…`.
    static var kokoroRoot: URL {
        root.appendingPathComponent("kokoro", isDirectory: true)
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

    /// One-time migration of Kokoro models from the old direct-pack cache and
    /// FluidAudio's macOS TTS cache.
    static func migrateKokoro() {
        let repo = kokoroRoot.appendingPathComponent("kokoro-82m-coreml", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: repo.path) else { return }

        // Old direct pack: ~/Library/Caches/idfon/speech-packs/kokoro-ane
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let pack = caches.appendingPathComponent("idfon/speech-packs/kokoro-ane", isDirectory: true)
            if migrate(from: pack, to: kokoroRoot) != nil { return }
        }
        // FluidAudio TTS cache: ~/.cache/fluidaudio/Models/kokoro-82m-coreml
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models/kokoro-82m-coreml", isDirectory: true)
        _ = migrate(from: legacy, to: repo)
    }
}
