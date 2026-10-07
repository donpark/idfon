import Foundation

/// Durable action audit: one JSON object per line under Application Support, so
/// a review of what a JSON-render artifact asked the app to do survives
/// relaunch (`docs/idfon-web-hybrid-plan.md`, P5).
final class ActionAudit: @unchecked Sendable {
    static let shared = ActionAudit()

    private let queue = DispatchQueue(label: "idfon.action-audit")
    private let encoder = JSONEncoder()

    private var url: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Idfon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("action-audit.ndjson")
    }

    func record(_ event: RenderAudit) {
        queue.async { [weak self] in
            guard let self, var line = try? self.encoder.encode(event) else { return }
            line.append(0x0A)
            let url = self.url
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }
}
