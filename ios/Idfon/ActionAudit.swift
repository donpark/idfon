import Foundation

/// Durable action audit: one JSON object per line under Application Support, so
/// a review of what a JSON-render artifact asked the app to do survives
/// relaunch (`docs/idfon-web-hybrid-plan.md`, P5).
final class ActionAudit: @unchecked Sendable {
    static let shared = ActionAudit()

    /// Rotate once the log passes this; keeps exactly one prior file (`*.1`),
    /// so the audit trail cannot grow without bound.
    static let maxBytes = 1 << 20

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
            Self.rotateIfNeeded(at: url, maxBytes: Self.maxBytes)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// Moves the log to `<name>.1` when it reaches `maxBytes`. Foundation-only
    /// and side-effect-explicit so a host check can exercise it.
    static func rotateIfNeeded(at url: URL, maxBytes: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size >= maxBytes else { return }
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}
