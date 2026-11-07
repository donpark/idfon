import Foundation

/// Cache-class store for per-turn replay audio (#202 P1/P2): what the caller
/// heard (agent turns) and said (caller turns), keyed by turn id. Foundation-
/// only so `Checks/TurnReplayStoreCheck` runs it standalone (run as
/// `swiftc -o /tmp/turnreplaycheck <app>/TurnReplayStore.swift
/// <app>/Checks/TurnReplayStoreCheck/main.swift && /tmp/turnreplaycheck`).
///
/// `Library/Caches`: the system may reclaim any file — a miss re-captures or
/// re-fetches. Eviction keeps the newest audio under `budgetBytes`.
enum TurnReplayStore {
    /// Total on-disk budget; a turn wav is ~3 MB/min at 24 kHz mono s16.
    static let budgetBytes: Int64 = 64 * 1024 * 1024
    /// A turn older than this is stale anyway.
    static let maxAge: TimeInterval = 30 * 24 * 3600

    static func directory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("idfon-turn-replay")
    }

    static func url(for turnKey: String) -> URL? {
        let url = directory().appendingPathComponent(fileName(turnKey))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Store the turn's mono samples as its replay audio, trimmed to the
    /// speech (leading/trailing silence is listen-window slack).
    @discardableResult
    static func store(turnKey: String, samples: [Float], rate: Double) -> URL? {
        let trimmed = trim(samples)
        guard !trimmed.isEmpty, let data = wavMono(samples: trimmed, rate: rate) else { return nil }
        return store(turnKey: turnKey, wav: data)
    }

    /// Store wav bytes (a fetched ticket blob) under the turn key.
    @discardableResult
    static func store(turnKey: String, wav: Data) -> URL? {
        let dir = directory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(turnKey))
        do {
            try wav.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        evict(in: dir)
        return url
    }

    static func discard(turnKey: String) {
        try? FileManager.default.removeItem(at: directory().appendingPathComponent(fileName(turnKey)))
    }

    /// Drop silence at both ends (speech level near the relay endpointer's
    /// ~0.009, padded by room noise).
    static func trim(_ samples: [Float], threshold: Float = 0.02) -> [Float] {
        var start = 0
        var end = samples.count
        while start < end, abs(samples[start]) < threshold { start += 1 }
        while end > start, abs(samples[end - 1]) < threshold { end -= 1 }
        return Array(samples[start..<end])
    }

    /// Mono s16 wav bytes (`TurnCapture`'s RIFF layout, one channel).
    static func wavMono(samples: [Float], rate: Double) -> Data? {
        guard !samples.isEmpty, rate > 0 else { return nil }
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + samples.count * 2)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(UInt32(rate))
        u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(samples.count * 2))
        for sample in samples {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32767)))
        }
        return data
    }

    /// Oldest-out under budget and max age (whole files only).
    static func evict(in dir: URL,
                      budgetBytes: Int64 = TurnReplayStore.budgetBytes,
                      maxAge: TimeInterval = TurnReplayStore.maxAge) {
        let fm = FileManager.default
        let now = Date()
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else { return }
        var total: Int64 = 0
        for url in files {
            guard let values = try? url.resourceValues(forKeys: keys),
                  let date = values.contentModificationDate else { continue }
            if now.timeIntervalSince(date) > maxAge {
                try? fm.removeItem(at: url)
            }
        }
        // Newest first: everything past the budget goes.
        let kept = files.compactMap { url -> (URL, Date, Int64)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let date = values.contentModificationDate else { return nil }
            return (url, date, Int64(values.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }
        for (url, _, size) in kept {
            total += size
            if total > budgetBytes {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Filesystem-safe name for a turn id (call ids are base36 + dashes).
    static func fileName(_ turnKey: String) -> String {
        let safe = turnKey.map { c -> Character in
            c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." ? c : "_"
        }
        return String(safe) + ".wav"
    }
}
