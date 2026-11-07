import AVFAudio
import Foundation

/// Pre-rendered backchannel cues (#199). A backchannel is 1–4 words and must
/// land while the caller is still talking, so the hot path may not await an
/// AFM call or a fresh synthesis. The fixed safe pool is rendered once per
/// (engine, voice, language) into `Library/Caches` and played from memory on
/// the AEC bus. Cache-class: the system may reclaim it; it re-renders.
@MainActor
final class BackchannelCache {
    static let shared = BackchannelCache()

    /// Bump when the pool, voice selection, or file format changes.
    private static let version = 1
    /// Disk budget across every voice/language; a pool is a few hundred KB.
    private static let budgetBytes: Int64 = 8 * 1024 * 1024
    private static let maxKeys = 12

    private var cues: [String: AVAudioPCMBuffer] = [:]
    private var readyKey: String?
    /// The key this call wants. A render for a different key must not publish
    /// (the old voice would otherwise play after a voice/language change).
    private var activeKey: String?
    /// Serializes renders: a per-contact backend prepare must not race a
    /// global prewarm into the same files.
    private var chain: Task<Void, Never>?

    private init() {}

    /// The pre-rendered audio for `text`, or nil when this engine/language is
    /// not cached (the caller falls back to on-demand synthesis).
    func cue(for text: String) -> (text: String, buffer: AVAudioPCMBuffer)? {
        guard readyKey == activeKey, let buffer = cues[text] else { return nil }
        return (text, buffer)
    }

    var isReady: Bool { readyKey == activeKey && !cues.isEmpty }

    /// Render the pool in the background. Idempotent and serialized.
    func prepare(backend: TtsBackend, language: String) async {
        let key = Self.key(backend: backend, language: language)
        activeKey = key
        guard readyKey != key else { return }
        let previous = chain
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.readyKey != key else { return }
            await self.render(backend: backend, language: language, key: key)
        }
        chain = task
        await task.value
    }

    private func render(backend: TtsBackend, language: String, key: String) async {
        let pool = Self.pool(for: language)
        guard !pool.isEmpty else {
            // No cue set for this language yet: keep the on-demand path.
            guard key == activeKey else { return }
            cues = [:]
            readyKey = key
            return
        }
        let dir = Self.directory(key: key)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if pool.contains(where: { Self.load(dir.appendingPathComponent(Self.fileName($0))) == nil }) {
            await Self.renderMissing(pool, backend: backend, dir: dir)
        }
        var loaded: [String: AVAudioPCMBuffer] = [:]
        for text in pool {
            if let buffer = Self.load(dir.appendingPathComponent(Self.fileName(text))) {
                loaded[text] = buffer
            }
        }
        // A newer prepare may have won while this render ran: never publish
        // the wrong voice.
        guard key == activeKey else { return }
        cues = loaded
        readyKey = key
        Self.touch(dir)
        Self.evict(keeping: key)
        Automation.mark("voice: backchannel cache key=\(key) cues=\(loaded.count)/\(pool.count)")
    }

    /// Cap the cache across voices/languages: drop other app-version dirs,
    /// then evict least-recently-used key dirs over the byte/count budget.
    /// The active key is never evicted.
    private static func evict(keeping key: String) {
        let fm = FileManager.default
        let root = modelCachesDirectory("backchannels")
        let children = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let current = "v\(version)-"
        var entries: [(url: URL, bytes: Int64, used: Date)] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            guard child.lastPathComponent.hasPrefix(current) else {
                try? fm.removeItem(at: child) // an older cache version
                continue
            }
            entries.append((child, size(of: child), values?.contentModificationDate ?? .distantPast))
        }
        entries.sort { $0.used > $1.used } // newest first
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var count = entries.count
        for entry in entries.reversed() where entry.url.lastPathComponent != key {
            guard total > budgetBytes || count > maxKeys else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.bytes
            count -= 1
            Automation.mark("voice: backchannel cache evicted \(entry.url.lastPathComponent)")
        }
    }

    private static func size(of dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// LRU stamp: a cache hit for this key must survive the next eviction.
    private static func touch(_ dir: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
    }

    /// Synthesize only the missing files with a throwaway engine whose sink is
    /// a recorder, never the live mouth.
    private static func renderMissing(_ pool: [String], backend: TtsBackend, dir: URL) async {
        let engine = SpeechEngines.makeTts(backend)
        await engine.prepare()
        let recorder = RecordingSink()
        engine.playback = recorder
        for text in pool where load(dir.appendingPathComponent(fileName(text))) == nil {
            recorder.reset()
            await engine.speak(text)
            guard let buffers = recorder.buffers, let first = buffers.first else {
                Automation.mark("voice: backchannel render empty text=\(text)")
                continue
            }
            do {
                let file = try AVAudioFile(
                    forWriting: dir.appendingPathComponent(fileName(text)),
                    settings: first.format.settings)
                for buffer in buffers { try file.write(from: buffer) }
            } catch {
                Automation.mark("voice: backchannel write failed \(error.localizedDescription)")
            }
        }
        engine.playback = nil
    }

    // MARK: - pool and files

    /// The cue set is English today (`BackchannelFiller`'s prompt is
    /// English-only); other languages keep the on-demand path until their
    /// pool is defined.
    private static func pool(for language: String) -> [String] {
        language.lowercased().hasPrefix("en") ? BackchannelFiller.safePool() : []
    }

    private static func key(backend: TtsBackend, language: String) -> String {
        let voice = backend == .apple
            ? (SpeechVoice.best(language: language)?.identifier ?? "default")
            : "default"
        return "v\(version)-\(backend.rawValue)-\(slug(language))-\(slug(voice))"
    }

    private static func directory(key: String) -> URL {
        modelCachesDirectory("backchannels").appendingPathComponent(key)
    }

    private static func fileName(_ text: String) -> String {
        slug(text) + ".caf"
    }

    private static func slug(_ text: String) -> String {
        let out = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(out).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-").prefix(48))
    }

    private static func load(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil
        else { return nil }
        return buffer
    }
}

/// Collects what an engine would have played, so the cache can render through
/// the same `speak` path as a live utterance without touching the bus.
private final class RecordingSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [AVAudioPCMBuffer] = []

    var buffers: [AVAudioPCMBuffer]? {
        lock.lock()
        defer { lock.unlock() }
        return captured.isEmpty ? nil : captured
    }

    func reset() {
        lock.lock()
        captured.removeAll()
        lock.unlock()
    }

    func play(wav: Data) async {}

    func play(_ buffer: AVAudioPCMBuffer) async {
        lock.lock()
        captured.append(buffer)
        lock.unlock()
    }

    func playLooping(_ buffer: AVAudioPCMBuffer) {}

    func playStream(_ buffer: AVAudioPCMBuffer, done: (() -> Void)?) {
        lock.lock()
        captured.append(buffer)
        lock.unlock()
        done?()
    }

    func stopPlayback() {}
}
