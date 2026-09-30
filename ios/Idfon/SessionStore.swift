import Foundation

/// Per-conversation session assets, app-side: the message log plus artifact
/// bytes, keyed by identity and conversation.
///
/// Ephemeral by default (the OS caches directory); the "persist logs" opt-in
/// moves the root to Application Support so a session survives OS cache
/// pressure. Nothing here is served to peers — only the user-visible
/// `Documents/Shared` directory is (see `DaemonClient.startSharedProvider`).
final class SessionStore {
    static let shared = SessionStore()

    /// Serializes file access off the main actor; the stores are small and the
    /// log is append-only.
    private let queue = DispatchQueue(label: "idfon.session-store")
    private let persistKey = "idfon.persistSessionLogs"

    /// User opt-in: keep session logs across cache pressure.
    var persistLogs: Bool {
        get { UserDefaults.standard.bool(forKey: persistKey) }
        set { UserDefaults.standard.set(newValue, forKey: persistKey) }
    }

    /// One persisted message. `text` is the raw body (plain text or an
    /// `IDFON-*/1` envelope) so restoring re-parses through `MessageKind`.
    struct StoredMessage: Codable {
        let id: String
        let peerId: String
        let text: String
        let outgoing: Bool
        let timestamp: Date
        let conversation: String?
    }

    private func base() -> URL {
        let directory = persistLogs ? FileManager.SearchPathDirectory.applicationSupportDirectory
                                    : FileManager.SearchPathDirectory.cachesDirectory
        let root = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
            .appendingPathComponent("idfon/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Conversation ids come from events and may be empty (1:1); never let one
    /// escape the root.
    private func sanitize(_ value: String?) -> String {
        let name = value.flatMap { $0.isEmpty ? nil : $0 } ?? "_direct"
        return name.replacingOccurrences(of: "/", with: "_")
    }

    private func directory(identity: String, conversation: String?) -> URL {
        let dir = base()
            .appendingPathComponent(sanitize(identity), isDirectory: true)
            .appendingPathComponent(sanitize(conversation), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Log

    func append(identity: String, conversation: String?, _ message: StoredMessage) {
        queue.async {
            let file = self.directory(identity: identity, conversation: conversation)
                .appendingPathComponent("log.jsonl")
            guard var line = try? JSONEncoder().encode(message) else { return }
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file)
            }
        }
    }

    /// Every conversation of an identity, in append order.
    func load(identity: String) -> [StoredMessage] {
        let root = base().appendingPathComponent(sanitize(identity), isDirectory: true)
        guard let conversations = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        var messages: [StoredMessage] = []
        for conversation in conversations {
            let file = conversation.appendingPathComponent("log.jsonl")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let message = try? decoder.decode(StoredMessage.self, from: Data(line.utf8)) {
                    messages.append(message)
                }
            }
        }
        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Artifacts

    /// Cached bytes for an artifact the chat fetched, so reopening it renders
    /// without refetching. Stored per conversation, next to the log.
    func storeArtifact(identity: String, conversation: String?, path: String, data: Data) {
        queue.async {
            let file = self.directory(identity: identity, conversation: conversation)
                .appendingPathComponent("artifacts", isDirectory: true)
                .appendingPathComponent(self.sanitize(path))
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file)
        }
    }

    func artifact(identity: String, conversation: String?, path: String) -> Data? {
        let file = directory(identity: identity, conversation: conversation)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(sanitize(path))
        return try? Data(contentsOf: file)
    }

    /// Cache for ticket-addressed artifacts, keyed by peer + artifact path.
    /// Only immutable blob artifacts are cached here; a `/fs/<path>` fetch is
    /// live and deliberately not cached (a delete or rename must be visible).
    func cacheArtifact(peer: String, path: String, data: Data) {
        storeArtifact(identity: "_cache", conversation: peer, path: path, data: data)
    }

    func cachedArtifact(peer: String, path: String) -> Data? {
        artifact(identity: "_cache", conversation: peer, path: path)
    }

    // MARK: - Snapshot form

    /// Whole-log blob, used by the iOS store (its message model is richer than
    /// the append-only `StoredMessage` line). Same cache root and persist flag.
    func saveSnapshot(identity: String, data: Data) {
        queue.async {
            let file = self.base()
                .appendingPathComponent(self.sanitize(identity), isDirectory: true)
                .appendingPathComponent("messages.json")
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file)
        }
    }

    func loadSnapshot(identity: String) -> Data? {
        let file = base()
            .appendingPathComponent(sanitize(identity), isDirectory: true)
            .appendingPathComponent("messages.json")
        return try? Data(contentsOf: file)
    }
}
