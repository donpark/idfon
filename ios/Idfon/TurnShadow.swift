import AVFAudio
import CryptoKit
import FluidAudio
import Foundation
import TygerVoice
import TygerVoiceCoreAI

/// Model delivery for the turn engine — download-on-first-use (2026-10-21
/// decision): the tier's artifacts come from a pinned manifest (`url_base` +
/// per-file sha256/size — the `scripts/pack-tyger-models.mjs` shape) into
/// `Documents/tyger-models/`, the same place side-loading uses, so either
/// path works. Only the device's tier is fetched (CoreAI fp16 on iOS 27+,
/// else the three CoreML packages). Fail-open: any failure just means classic
/// turn-taking.
enum TygerModelStore {
    struct Manifest: Decodable {
        struct Entry: Decodable {
            /// Relative path under `Documents/tyger-models/` (bundles are
            /// flattened to their files).
            let name: String
            /// Flat download filename (`/` -> `__`).
            let asset: String
            let sha256: String
            let bytes: Int
        }
        let url_base: String
        let files: [Entry]
    }

    /// The manifest URL: `IDFON_TYGER_MODELS` / `-tygermodels <url>` override
    /// for testing; the default is the packed release
    /// (`scripts/pack-tyger-models.mjs` uploads to one).
    static var manifestURL: URL? {
        if let override = overrideURL(), let url = URL(string: override) { return url }
        return URL(string: "https://huggingface.co/donpark/tyger-models/resolve/main/manifest.json")
    }

    private static func overrideURL() -> String? {
        if let env = ProcessInfo.processInfo.environment["IDFON_TYGER_MODELS"], !env.isEmpty { return env }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-tygermodels"), i + 1 < args.count { return args[i + 1] }
        return nil
    }

    private static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tyger-models")
    private static let lock = NSLock()
    private static var tasks: [String: Task<Bool, Never>] = [:]

    /// Download the tier's files once per process (already-present files are
    /// kept: side-loading and earlier fetches both count). Returns whether
    /// everything needed is on disk afterwards.
    static func ensure(tier: String) async -> Bool {
        let task: Task<Bool, Never> = lock.withLock {
            if let existing = tasks[tier] { return existing }
            let created = Task { await fetch(tier: tier) }
            tasks[tier] = created
            return created
        }
        return await task.value
    }

    private static func fetch(tier: String) async -> Bool {
        guard let manifestURL else { return false }
        do {
            let (data, _) = try await URLSession.shared.data(from: manifestURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard let base = URL(string: manifest.url_base) else { return false }
            let wanted = manifest.files.filter { $0.name.hasPrefix("\(tier)/") }
            guard !wanted.isEmpty else { return false }
            // Parallel fetches: a tier is a handful of large files and the
            // host is a CDN — the wall time drops roughly with the width.
            return await withTaskGroup(of: Bool.self) { group in
                for entry in wanted {
                    let dest = root.appendingPathComponent(installPath(for: entry.name))
                    if FileManager.default.fileExists(atPath: dest.path) { continue }
                    group.addTask { await fetchOne(entry, base: base) }
                }
                var ok = true
                for await fetched in group { ok = ok && fetched }
                return ok
            }
        } catch {
            Automation.mark("tyger models: fetch failed \(error.localizedDescription)")
            return false
        }
    }

    /// One manifest entry: download, verify, install. Never throws.
    private static func fetchOne(_ entry: Manifest.Entry, base: URL) async -> Bool {
        let dest = root.appendingPathComponent(installPath(for: entry.name))
        Automation.mark("tyger models: fetching \(entry.asset) \(entry.bytes / 1_000_000)MB")
        guard let (tmp, _) = try? await URLSession.shared.download(from: base.appendingPathComponent(entry.asset)),
              sha256(of: tmp) == entry.sha256 else {
            Automation.mark("tyger models: checksum mismatch \(entry.asset)")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            Automation.mark("tyger models: install failed \(entry.asset)")
            return false
        }
        Automation.mark("tyger models: installed \(entry.name)")
        return true
    }

    /// Install paths follow the loaders' expectations — and the side-load
    /// layout they already document: CoreAI bundles live under `coreai/`, the
    /// CoreML packages at the root of `Documents/tyger-models/`.
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
/// marks its events for a decision-log diff. It changes NO behavior — the
/// segmenter's commit stays authoritative until the diff says otherwise (the
/// swap-over convention; `docs/voice-tyger-option.md` P3).
///
/// Tier: Core AI (iOS 27+) — the shipping rung is fp16 (2026-10-21 ruling;
/// `CoreAITurnModel` prefers the float16 assets and falls back to fp32) — when
/// its `.aimodel`s are side-loaded in `Documents/tyger-models/coreai/`;
/// otherwise CoreML (TygerEncoder fp16 on ANE, TygerEncoderDyn at startup,
/// TygerStep fp32) — the accepted pre-27 iOS tier — from
/// `Documents/tyger-models/`. With no models there the shadow stays off and
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
    /// The active-mode sink (the tyger option): non-FRAME decisions as they
    /// fire. The Automation marks stay either way (the diff log).
    var onDecision: ((String) -> Void)?

    /// nil when no models are available.
    static func start() async -> TurnShadow? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tyger-models")
        // Tiers load only when already present — an ASR-warmup race must
        // never pull a 0.8 GB tier. A late shadow costs nothing — classic
        // drives until it appears — and a failed load just means classic for
        // this call.
        if #available(iOS 27.0, *),
           let coreai = try? CoreAITurnModel(directory: dir.appendingPathComponent("coreai")) {
            Automation.mark("turn-shadow: tier CoreAI (\(coreai.usesFloat16 ? "fp16" : "fp32") GPU)")
            return TurnShadow(model: coreai)
        }
        let enc = dir.appendingPathComponent("TygerEncoder.mlpackage")
        let dyn = dir.appendingPathComponent("TygerEncoderDyn.mlpackage")
        let step = dir.appendingPathComponent("TygerStep.mlpackage")
        guard FileManager.default.fileExists(atPath: enc.path),
              FileManager.default.fileExists(atPath: dyn.path),
              FileManager.default.fileExists(atPath: step.path) else {
            Automation.mark("turn-shadow: no models at \(dir.path)")
            return nil
        }
        guard let model = try? CoreMLTurnModel(encoderURL: enc, encoderDynURL: dyn, stepURL: step) else {
            Automation.mark("turn-shadow: model load failed")
            return nil
        }
        Automation.mark("turn-shadow: tier CoreML (fp16/ANE)")
        return TurnShadow(model: model)
    }

    private init(model: TurnModel) {
        engine = TurnEngine(model: model, rules: TurnRulesCABI())
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
        let events = engine.feed(userHop: hop, agentHop: agent, mode: mode)
        for e in events where e.kind != "FRAME" {
            let turn = (e.dict["turn_s"] as? Double).map { String(format: "%.2f", $0) } ?? "-"
            let onset = (e.dict["onset_s"] as? Double).map { String(format: "%.2f", $0) } ?? "-"
            Automation.mark("turn-shadow: \(e.kind) frame=\(e.frame) turn_s=\(turn) onset_s=\(onset)")
            onDecision?(e.kind)
        }
    }
}
