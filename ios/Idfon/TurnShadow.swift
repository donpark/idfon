import AVFAudio
import CryptoKit
import FluidAudio
import Foundation
import TygerVoice
import TygerVoiceCoreAI

/// Model delivery for the turn engine — download behind the `VoiceModelGate`
/// approval (2026-10-27 rule): the tier's artifacts come from a pinned
/// manifest (`url_base` + per-file sha256/size — the
/// `scripts/pack-tyger-models.mjs` shape) into `TygerModelStore.root`
/// (`Library/Caches/tyger-models` — cache-class, system-reclaimable), the
/// same place side-loading uses, so
/// either path works. iOS 27+ may fetch the prefix and loadable CoreAI tier;
/// older iOS keeps classic turn-taking and stores no Tyger tier.
enum TygerModelStore {
    struct Manifest: Codable {
        struct Entry: Codable {
            /// Relative path under `Documents/tyger-models/` (bundles are
            /// flattened to their files).
            let name: String
            /// Flat download filename (`/` -> `__`).
            let asset: String
            let sha256: String
            let bytes: Int
            /// "ios" | "mac" for an AOT arch child; nil = every platform.
            let platform: String?
        }
        let url_base: String
        let files: [Entry]
    }

    private struct InstalledTier: Codable {
        let files: [Manifest.Entry]
    }

    final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private let tier: String
        private let total: Int64
        private let report: @MainActor @Sendable (String, Int64, Int64) -> Void
        private var bytes: [String: Int64] = [:]

        init(tier: String, total: Int64, report: @escaping @MainActor @Sendable (String, Int64, Int64) -> Void) {
            self.tier = tier
            self.total = total
            self.report = report
        }

        func set(_ name: String, bytes value: Int64, notify: Bool = true) {
            lock.lock()
            bytes[name] = max(0, value)
            let completed = min(total, bytes.values.reduce(0, +))
            lock.unlock()
            if notify { Task { @MainActor in report(tier, completed, total) } }
        }

        func publish() {
            lock.lock()
            let completed = min(total, bytes.values.reduce(0, +))
            lock.unlock()
            Task { @MainActor in report(tier, completed, total) }
        }
    }

    /// The manifest URL: `IDFON_TYGER_MODELS` / `-tygermodels <url>` override
    /// for testing; the default is the packed release
    /// (`scripts/pack-tyger-models.mjs` uploads to one).
    static var manifestURL: URL? {
        if let override = overrideURL(), let url = URL(string: override) { return url }
        return URL(string: "https://files.idfon.net/models/tyger/manifest.json")
    }

    /// Mirror used only when the durable host cannot serve the manifest at all.
    /// Ignored with an explicit override (a test override must not silently
    /// fall back to a release set).
    static var mirrorManifestURL: URL? {
        URL(string: "https://huggingface.co/donpark/tyger-models/resolve/main/manifest.json")
    }

    private static func overrideURL() -> String? {
        if let env = ProcessInfo.processInfo.environment["IDFON_TYGER_MODELS"], !env.isEmpty { return env }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-tygermodels"), i + 1 < args.count { return args[i + 1] }
        return nil
    }

    /// Which AOT arch children this process needs. A Core AI container ships one
    /// child per architecture (iPhone vs Mac), each a full copy of the weights.
    static var platform: String {
        #if os(macOS)
        "mac"
        #else
        "ios"
        #endif
    }

    /// The install root: `Library/Caches/tyger-models` (2026-10-27) — the
    /// weights are re-downloadable, so the pack is cache-class by Apple's
    /// definition: the file system may delete it when asked to free space
    /// (`NSURLIsPurgeableKey`), and the gate re-fetches. The loaders read the
    /// same root (fail-open to classic when it is gone).
    static let root = modelCachesDirectory("tyger-models")
    private static let lock = NSLock()
    private static var tasks: [String: (id: UUID, task: Task<Bool, Never>)] = [:]

    /// One-time cleanup/migration of model-pack layouts (idempotent, cheap
    /// when nothing is stray). The pack is cache-class since 2026-10-27
    /// (`Library/Caches` — the file system may delete it when asked to free
    /// space; the gate re-fetches). Everything found in the older layouts
    /// moves into the current root (existing files win, nothing is
    /// overwritten): the pre-2026-10-27 `Documents/tyger-models` side-load
    /// dir, the previous Application Support root, and tier dirs misplaced at
    /// the support root. The product-dead `pathc` student tier (removed
    /// 2026-10-25) is deleted instead.
    static func migrateLegacyLayout() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tyger-models")
        let tygerChildren = ["coreai", "coreml", "mlx", "TygerEncoder.mlpackage",
                             "TygerEncoderDyn.mlpackage", "TygerStep.mlpackage"]
        for source in [docs, support] where fm.fileExists(atPath: source.path) {
            for item in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
                let name = item.lastPathComponent
                let dest = name == "tyger-models" ? root
                    : (tygerChildren.contains(name) ? root.appendingPathComponent(name) : nil)
                if source == docs && name == "pathc" {
                    try? fm.removeItem(at: item) // tier removed from the product 2026-10-25
                } else if let dest {
                    // `modelCachesDirectory` creates the root eagerly; an
                    // empty destination is that placeholder, not content.
                    if fm.fileExists(atPath: dest.path) {
                        guard ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? []).isEmpty else { continue }
                        try? fm.removeItem(at: dest)
                    }
                    try? fm.moveItem(at: item, to: dest)
                }
            }
            if source == docs, ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).isEmpty {
                try? fm.removeItem(at: source)
            }
        }
        // Purgeable probe: prove the Caches home is evictable on this OS build.
        let probe = root.appendingPathComponent(".purge-probe")
        fm.createFile(atPath: probe.path, contents: Data())
        let purgeable = (try? probe.resourceValues(forKeys: [.isPurgeableKey]))?.isPurgeable
        Automation.mark("voice: model store purgeable=\(purgeable.map { String(describing: $0) } ?? "?")")
        try? fm.removeItem(at: probe)
    }

    /// Pre-27 devices use classic turn-taking; their Tyger cache is retired.
    static func purgePre27Store(at directory: URL = root) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The reclaim condition/action we own (2026-10-27). Condition: free
    /// space for important usage below `freeBytes`. Action: delete the store
    /// root — the tier is re-downloadable, loaders fail open to classic, and
    /// the gate re-fetches on the next voice use. This is deliberate: on iOS
    /// `NSURLIsPurgeableKey` is read-only and reads `false` even in Caches
    /// (verified iOS 27.1), so no file-system eviction will reclaim it for
    /// us. The heavier Apple-native alternative is Background Assets
    /// (`AssetPackManager` — system-scheduled download + system eviction).
    static func reclaimIfDiskLow(freeBytes: Int64 = 2_000_000_000) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        Automation.mark("voice: model store free=\(free / 1_000_000)MB reclaim-below=\(freeBytes / 1_000_000)MB")
        guard free < freeBytes else { return }
        try? FileManager.default.removeItem(at: root)
        Automation.mark("voice: turn tier reclaimed (\(free / 1_000_000)MB free)")
    }

    /// Reconcile the selected tier with its published manifest on each approved check.
    static func ensure(
        tier: String,
        onProgress: (@MainActor @Sendable (String, Int64, Int64) -> Void)? = nil
    ) async -> Bool {
        let (id, task): (UUID, Task<Bool, Never>) = lock.withLock {
            if let existing = tasks[tier] { return (existing.id, existing.task) }
            let id = UUID()
            let created = Task { await fetch(tier: tier, onProgress: onProgress) }
            tasks[tier] = (id, created)
            return (id, created)
        }
        let result = await task.value
        lock.withLock {
            if tasks[tier]?.id == id { tasks[tier] = nil }
        }
        return result
    }

    private static func fetch(
        tier: String,
        onProgress: (@MainActor @Sendable (String, Int64, Int64) -> Void)?
    ) async -> Bool {
        var urls: [URL] = []
        if let primary = manifestURL { urls.append(primary) }
        if overrideURL() == nil, let mirror = mirrorManifestURL { urls.append(mirror) }
        for url in urls {
            if await fetch(manifest: url, tier: tier, onProgress: onProgress) { return true }
        }
        return false
    }

    private static func fetch(
        manifest url: URL,
        tier: String,
        onProgress: (@MainActor @Sendable (String, Int64, Int64) -> Void)?
    ) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard let base = URL(string: manifest.url_base) else { return false }
            let wanted = manifest.files.filter {
                $0.name.hasPrefix("\(tier)/") && ($0.platform == nil || $0.platform == Self.platform)
            }
            guard !wanted.isEmpty else { return false }

            let stateURL = root.appendingPathComponent(".installed-\(tier).json")
            let installed = (try? Data(contentsOf: stateURL))
                .flatMap { try? JSONDecoder().decode(InstalledTier.self, from: $0) }
            let oldByName = Dictionary(uniqueKeysWithValues: (installed?.files ?? []).map { ($0.name, $0) })
            // Retire only assets this tier previously owned and the new manifest no longer names.
            for old in obsoleteAssets(installed: installed?.files ?? [], wanted: wanted) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(installPath(for: old.name)))
            }

            let total = wanted.reduce(Int64(0)) { $0 + Int64($1.bytes) }
            let progress = Progress(tier: tier, total: total, report: onProgress ?? { _, _, _ in })
            var pending: [Manifest.Entry] = []
            for entry in wanted {
                let dest = root.appendingPathComponent(installPath(for: entry.name))
                let changed = oldByName[entry.name].map { $0.sha256 != entry.sha256 } ?? false
                let verifyHash = entry.bytes <= 1_048_576 || changed
                if Self.existingFileMatches(entry, at: dest, verifyHash: verifyHash) {
                    progress.set(entry.name, bytes: Int64(entry.bytes), notify: false)
                } else {
                    pending.append(entry)
                }
            }
            progress.publish()

            let needed = pending.reduce(Int64(0)) { $0 + Int64($1.bytes) }
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? .max
            let reserve: Int64 = 64_000_000
            guard needed == 0 || free >= needed + reserve else {
                Automation.mark("tyger models: insufficient space tier=\(tier) need=\((needed + reserve) / 1_000_000)MB free=\(free / 1_000_000)MB")
                return false
            }

            let ok = await withTaskGroup(of: Bool.self) { group in
                for entry in pending {
                    group.addTask {
                        await fetchOne(entry, base: base) { bytes in
                            progress.set(entry.name, bytes: bytes)
                        }
                    }
                }
                var allInstalled = true
                for await fetched in group { allInstalled = fetched && allInstalled }
                return allInstalled
            }
            guard ok else { return false }
            let snapshot = InstalledTier(files: wanted)
            try JSONEncoder().encode(snapshot).write(to: stateURL, options: .atomic)
            return true
        } catch {
            Automation.mark("tyger models: fetch failed \(error.localizedDescription)")
            return false
        }
    }

    static func obsoleteAssets(installed: [Manifest.Entry], wanted: [Manifest.Entry]) -> [Manifest.Entry] {
        let names = Set(wanted.map(\.name))
        return installed.filter { !names.contains($0.name) }
    }

    static func existingFileMatches(_ entry: Manifest.Entry, at url: URL, verifyHash: Bool = true) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size == entry.bytes else { return false }
        return !verifyHash || sha256(of: url) == entry.sha256
    }

    /// One manifest entry: download, verify, install. Never throws.
    private static func fetchOne(
        _ entry: Manifest.Entry,
        base: URL,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async -> Bool {
        let dest = root.appendingPathComponent(installPath(for: entry.name))
        Automation.mark("tyger models: fetching \(entry.asset) \(entry.bytes / 1_000_000)MB")
        guard let (tmp, response) = try? await ModelAssetDownload.fetch(
            base.appendingPathComponent(entry.asset), onProgress: onProgress) else {
            Automation.mark("tyger models: download failed \(entry.asset)")
            return false
        }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              sha256(of: tmp) == entry.sha256 else {
            try? FileManager.default.removeItem(at: tmp)
            Automation.mark("tyger models: checksum mismatch \(entry.asset)")
            return false
        }
        let backup = dest.appendingPathExtension("previous-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.moveItem(at: dest, to: backup)
            }
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                try? FileManager.default.removeItem(at: backup)
            } catch {
                if FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.moveItem(at: backup, to: dest)
                }
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Automation.mark("tyger models: install failed \(entry.asset)")
            return false
        }
        Automation.mark("tyger models: installed \(entry.name)")
        return true
    }

    private final class ModelAssetDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse?), Error>?
        private var session: URLSession?
        private var finished = false
        private let onProgress: @Sendable (Int64) -> Void

        private init(
            continuation: CheckedContinuation<(URL, URLResponse?), Error>,
            onProgress: @escaping @Sendable (Int64) -> Void
        ) {
            self.continuation = continuation
            self.onProgress = onProgress
        }

        static func fetch(
            _ url: URL,
            onProgress: @escaping @Sendable (Int64) -> Void
        ) async throws -> (URL, URLResponse?) {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = ModelAssetDownload(continuation: continuation, onProgress: onProgress)
                let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
                delegate.session = session
                session.downloadTask(with: url).resume()
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            onProgress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("tyger-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                finish(.success((destination, downloadTask.response)))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }

        private func finish(_ result: Result<(URL, URLResponse?), Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let session = self.session
            self.session = nil
            lock.unlock()
            continuation?.resume(with: result)
            session?.finishTasksAndInvalidate()
        }
    }

    /// Install paths follow the loaders' expectations — and the side-load
    /// layout they already document: CoreAI bundles live under `coreai/`, the
    /// CoreML packages at the root of `TygerModelStore.root`.
    private static func installPath(for name: String) -> String {
        name.hasPrefix("coreml/") ? String(name.dropFirst("coreml/".count)) : name
    }

    /// Streaming SHA-256 of a downloaded file (the bundles are hundreds of MB).
    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Shadow turn-taker (iOS): runs the turn engine beside the text Segmenter and
/// marks its events for a decision-log diff. In `tyger` mode its ENDPOINT can
/// only shorten a turn; the segmenter's gap stays the fallback (and the
/// ceiling), so nothing here can hold a turn open (`docs/voice-tyger-option.md`).
///
/// Tier: Core AI (iOS 27+) — the default rung is fp32 (2026-10-27 ruling; the
/// fp16 pair drifts `p_end` near the endpoint gate and is opt-in via
/// IDFON_TURN_PRECISION=fp16) — from `TygerModelStore.root/coreai/`;
/// otherwise CoreML (TygerEncoder fp16 on ANE, TygerEncoderDyn at startup,
/// TygerStep fp32) — the accepted pre-27 iOS tier — from
/// `TygerModelStore.root`. Delivery: `TygerModelStore` behind the
/// `VoiceModelGate` approval. With no models there the shadow stays off and
/// says so in the Automation log.
///
/// Phase-1 note: the agent channel is now REAL (AudioIO's playback observers —
/// `audioPlayback` — feed a second tap), so echo suppression and BARGE see the
/// agent's own voice. The tag timeline is the schedule time (the same stand-in
/// as the tyger relay's TYGER_TAG_LAG_MS), and hops pair 1:1 from the two taps'
/// queues.
final class TurnShadow: AudioCaptureObserver, AudioPlaybackObserver {
    private let engine: TurnEngine
    private let tap: TurnTap
    private let agentTap: TurnTap
    /// Two-stream capture (mic + agent) for the voice-agent-trainer.
    private let capture: TurnCapture
    /// Agent-channel hops waiting for their user hop (paired 1:1 in consume).
    private var agentHops: [[Float]] = []
    /// Serial, off the audio render thread: inference never runs in a tap callback.
    private let queue = DispatchQueue(label: "idfon.turn-shadow")
    /// Pipeline bookkeeping (tap thread vs this queue): `stopped` makes `stop`
    /// prompt and idempotent; `queuedFeeds` bounds the backlog. Capture is
    /// real-time and CPU-tier inference is not — a shadow may skip buffers, but
    /// it must never queue unbounded work (the 2026-10-22 hangup watchdog kill:
    /// stop()'s `queue.sync` drained minutes of backlogged hops while the CPU
    /// burned until the system killed the app).
    private let stateLock = NSLock()
    private var stopped = false
    private var queuedFeeds = 0
    private static let maxQueuedFeeds = 50 // ~2 s of capture buffers

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private var mode = "listen"
    /// Consecutive quiet 80 ms frames (the rules' VAD floor).
    private var quietFrames = 0
    /// A model ENDPOINT may only commit after this many quiet frames (~480 ms).
    /// The shipped student gate fires on 160 ms of `p_end` evidence, short
    /// enough to land on a mid-sentence hesitation (`docs/voice-tyger.md`).
    private static let endpointQuietFrames = 6
    private static let vadDb: Float = -50 // turns.rs VAD_DB
    /// One-time mark: did the second ear ever receive playback audio?
    private var sawAgentAudio = false
    /// The active-mode sink (the tyger option): non-FRAME decisions as they
    /// fire. The Automation marks stay either way (the diff log).
    var onDecision: ((String) -> Void)?

    /// nil means classic turn-taking stays in charge.
    static func start() async -> TurnShadow? {
        guard #available(iOS 27.0, *) else {
            Automation.mark("turn-shadow: classic tier on pre-iOS 27")
            return nil
        }
        let dir = TygerModelStore.root
        if let prefix = loadPrefixTier(in: dir) { return prefix }
        do {
            let coreai = try CoreAITurnModel(directory: dir.appendingPathComponent("coreai"))
            let traits = traitsJSON(in: coreai.directory, step: coreai.stepModelName)
            Automation.mark("turn-shadow: tier CoreAI (\(coreai.usesFloat16 ? "fp16" : "fp32") GPU, \(coreai.stepModelName), traits \(traits == nil ? "default" : "student"))")
            Diag.log("turnmodel", ["tier": "coreai", "rung": coreai.usesFloat16 ? "fp16" : "fp32", "step": coreai.stepModelName, "traits": traits == nil ? "default" : "student", "ok": true])
            return TurnShadow(model: coreai, traits: traits,
                              meta: ["tier": "coreai", "rung": coreai.usesFloat16 ? "fp16" : "fp32",
                                     "step": coreai.stepModelName,
                                     "traits": traits == nil ? "default" : "student"])
        } catch {
            idfonLog("turnmodel: coreai load failed: \(error)")
            Diag.log("turnmodel", ["tier": "coreai", "ok": false, "error": String(describing: error)])
            return nil
        }
    }

    /// The one prefix load path, shared by the call-time tier and the
    /// `-turnprefixprobe` launch probe (same artifact lookup, step choice,
    /// initializer and sidecar rules).
    static func prefixModel(artifact: URL, in dir: URL) throws -> TurnPrefixModel {
        let student = dir.appendingPathComponent("StudentStep.mlpackage")
        let teacher = dir.appendingPathComponent("TygerStep.mlpackage")
        let step = FileManager.default.fileExists(atPath: student.path) ? student : teacher
        return try TurnPrefixModel(artifactURL: artifact, stepURL: step)
    }

    /// The 320 ms turn prefix tier (#132's split tier): a 102 MB layers-0-3 encoder
    /// under `<root>/prefix/`, batched two ears in one cache-aware call, beside the
    /// cut tier's files. Default on since the 2026-11-05 ruling (`IDFON_TURN_PREFIX=0`
    /// is the kill switch); a set but ambiguous or malformed value, a missing artifact
    /// or a malformed one simply returns nil and the caller keeps today's cut.
    private static func loadPrefixTier(in dir: URL) -> TurnShadow? {
        guard TurnPrefix.isEnabled(environment: ProcessInfo.processInfo.environment) else { return nil }
        guard let artifact = TurnPrefix.artifact(in: dir) else {
            Automation.mark("turn-shadow: prefix on, no artifact at \(dir.path)/prefix")
            Diag.log("turnmodel", ["tier": "prefix-320", "ok": false, "error": "no prefix artifact"])
            return nil
        }
        do {
            let model = try prefixModel(artifact: artifact, in: dir)
            let traits = traitsJSON(in: dir, step: model.stepModelName)
            let s = model.shape
            Automation.mark("turn-shadow: tier prefix-320 (\(artifact.lastPathComponent), cache \(s.cacheDepth)x\(s.layers), \(s.tapRowsPerChunk) rows/hop, \(model.stepModelName), traits \(traits == nil ? "default" : "student"))")
            Diag.log("turnmodel", ["tier": "prefix-320", "rung": "fp16-ane", "step": model.stepModelName,
                                   "traits": traits == nil ? "default" : "student",
                                   "cache_depth": "\(s.cacheDepth)", "layers": "\(s.layers)", "ok": true])
            return TurnShadow(model: model, traits: traits,
                              meta: ["tier": "prefix-320", "rung": "fp16-ane",
                                     "step": model.stepModelName,
                                     "traits": traits == nil ? "default" : "student"])
        } catch {
            Automation.mark("turn-shadow: prefix tier failed: \(error)")
            Diag.log("turnmodel", ["tier": "prefix-320", "ok": false, "error": String(describing: error)])
            return nil
        }
    }

    /// The rules knobs that travel with the student step (`student.traits.json`:
    /// `{"name", "decider": {ep_thr, …}}`) — thresholds are per-model and the
    /// teacher's triple costs the student ~9 pts of event agreement on live
    /// audio. nil (teacher step or no file): the bundled live-tuned defaults.
    private static func traitsJSON(in dir: URL, step: String) -> String? {
        guard step.hasPrefix("StudentStep") || step.hasPrefix("student_step_") else { return nil }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("student.traits.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decider = root["decider"],
              let json = try? JSONSerialization.data(withJSONObject: decider) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    private init(model: TurnModel, traits: String? = nil, meta: [String: String] = [:]) {
        engine = TurnEngine(model: model, rules: TurnRulesCABI(thresholdsJSON: traits),
                            trace: TurnTrace.fromEnvironment(meta: meta))
        tap = TurnTap(hopSize: TurnRuntime.hopSamples)
        agentTap = TurnTap(hopSize: TurnRuntime.hopSamples)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        capture = TurnCapture(dir: base.appendingPathComponent("turn-captures"))
        tap.onHop = { [weak self] samples in
            self?.consume(samples)
        }
        agentTap.onHop = { [weak self] samples in
            guard let self else { return }
            self.agentHops.append(samples) // already on the serial queue (tap.feed is)
            // Bounded: consume() pairs these 1:1 with user hops, and dropped
            // user feeds must not grow this queue forever.
            if self.agentHops.count > 50 {
                self.agentHops.removeFirst(self.agentHops.count - 50)
            }
        }
        AudioIO.shared.addCaptureObserver(self)
        AudioIO.shared.addPlaybackObserver(self)
    }

    /// The single mic source's raw buffers (the iOS seam; mac taps the ASR engine).
    func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let ch = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        feed(samples, rate: buffer.format.sampleRate)
    }

    func feed(_ samples: [Float], rate: Double) {
        stateLock.lock()
        let run = !stopped && queuedFeeds < Self.maxQueuedFeeds
        if run { queuedFeeds += 1 }
        stateLock.unlock()
        guard run else { return } // real-time: drop rather than backlog
        queue.async {
            defer {
                self.stateLock.lock()
                self.queuedFeeds -= 1
                self.stateLock.unlock()
            }
            guard !self.isStopped else { return }
            self.tap.feed(samples, rate: rate)
        }
    }

    /// What the playback bus is about to play (TTS + remote call audio) — the
    /// agent channel. Hop timing pairs 1:1 with the user's in `consume`.
    func audioPlayback(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let first = !sawAgentAudio
        sawAgentAudio = true
        stateLock.unlock()
        if first {
            Automation.mark("turn-shadow: agent audio first buffer frames=\(buffer.frameLength) rate=\(buffer.format.sampleRate)")
        }
        guard let ch = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        let rate = buffer.format.sampleRate
        guard !isStopped else { return }
        queue.async { self.agentTap.feed(samples, rate: rate) }
    }

    /// "listen" while the caller speaks, "speaking" while the agent plays.
    func setMode(_ mode: String) {
        queue.async { self.mode = mode }
    }

    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        AudioIO.shared.removeCaptureObserver(self)
        AudioIO.shared.removePlaybackObserver(self)
        queue.sync {
            engine.closeTrace()
            engine.reset()
            agentHops.removeAll()
        }
        if let url = capture.finish() {
            Automation.mark("turn-capture: \(url.path)")
        }
    }

    private func consume(_ hop: [Float]) {
        guard !isStopped else { return }
        let agent = agentHops.isEmpty ? [Float](repeating: 0, count: hop.count) : agentHops.removeFirst()
        capture.append(userHop: hop, agentHop: agent)
        for db in TurnRuntime.frameEnergy(hop) {
            quietFrames = db > Self.vadDb ? 0 : quietFrames + 1
        }
        let events = engine.feed(userHop: hop, agentHop: agent, mode: mode)
        for e in events where e.kind != "FRAME" {
            let turn = (e.dict["turn_s"] as? Double).map { String(format: "%.2f", $0) } ?? "-"
            let onset = (e.dict["onset_s"] as? Double).map { String(format: "%.2f", $0) } ?? "-"
            Automation.mark("turn-shadow: \(e.kind) frame=\(e.frame) turn_s=\(turn) onset_s=\(onset)")
            if e.kind == "ENDPOINT", quietFrames < Self.endpointQuietFrames {
                Automation.mark("turn-shadow: ENDPOINT held quiet_ms=\(quietFrames * 80)")
                continue
            }
            onDecision?(e.kind)
        }
    }
}
