import Foundation

/// The user-visible directory the daemon serves to granted peers at
/// `GET /fs/<path>` (see `DaemonClient.startSharedProvider`), plus the action
/// that promotes a session file into it so another peer can fetch it.
enum SharedFolder {
    static var url: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents.appendingPathComponent("Shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `data` into the shared root under `name` (a single path component;
    /// anything else is stripped) and returns the saved URL. The daemon serves
    /// it live, so no further call is needed — the provider is started at launch.
    @discardableResult
    static func save(_ data: Data, name: String, folder: String? = nil) -> URL? {
        var target = url
        if let folder, !folder.isEmpty {
            target.appendPathComponent((folder as NSString).lastPathComponent, isDirectory: true)
        }
        target.appendPathComponent((name as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            return target
        } catch {
            return nil
        }
    }
}
