import Foundation
import TygerVoice
import TygerVoiceCoreAI
import TygerVoiceMLX

/// Shadow turn-taker: runs the mac tier's turn engine beside the text
/// `Segmenter` and marks its events for a decision-log diff. It changes NO
/// behavior — the segmenter's 1.2 s no-change commit stays authoritative until
/// the diff says otherwise (the swap-over convention).
///
/// Phase-1 note: the agent channel is now REAL (PlaybackBus — Kokoro TTS wavs,
/// remote call audio, and call tones fan in at play time), so echo suppression
/// and BARGE see the agent's own voice. Gaps: the Apple-TTS fallback plays via
/// AVSpeechSynthesizer (system audio, no buffer seam) and a looping tone ring
/// is fed once. Hops pair 1:1 from the two taps' queues.
/// Tier: Core AI on macOS 27+ (oracle-exact; the distilled StudentStep step is
/// preferred when the checkout's `bench-results/tier-l4/coreai` (the shipped
/// L4 cut) has it; the L15 `bench-results/coreai` is the fallback, teacher
/// otherwise), MLX below.
final class TurnShadow: AudioPlaybackObserver {
    private let engine: TurnEngine
    private let tap: TurnTap
    private let agentTap: TurnTap
    /// Two-stream capture (mic + agent) for the voice-agent-trainer.
    private let capture: TurnCapture
    /// Agent-channel hops waiting for their user hop (paired 1:1 in consume).
    private var agentHops: [[Float]] = []
    /// Serial, off the audio render thread: the model's inference never runs
    /// inside a tap callback.
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

    /// nil when no turn model is available for this OS.
    static func start() -> TurnShadow? {
        if let prefix = loadPrefixTier() { return prefix }
        var model: TurnModel?
        // Calibration override: IDFON_TURN_TIER=coreai|mlx picks the tier.
        let tier = ProcessInfo.processInfo.environment["IDFON_TURN_TIER"]
        if tier != "mlx", #available(macOS 27.0, *) {
            do {
                model = try CoreAITurnModel() // the OS 27+ tier (GPU, oracle-exact)
            } catch {
                Diag.log("turnmodel", ["tier": "coreai", "ok": false, "error": String(describing: error)])
            }
        }
        if model == nil, MlxTurnModel.hasMetalLibrary {
            do {
                model = try MlxTurnModel() // legacy macOS 14-26 tier
            } catch {
                Diag.log("turnmodel", ["tier": "mlx", "ok": false, "error": String(describing: error)])
            }
        }
        guard let model else {
            Automation.mark("turn-shadow: no turn model available")
            Diag.log("turnmodel", ["ok": false, "error": "no tier available"])
            return nil
        }
        var rung: String?
        var step: String?
        var traits: String?
        if #available(macOS 27.0, *), let core = model as? CoreAITurnModel {
            rung = core.usesFloat16 ? "fp16" : "fp32"
            step = core.stepModelName
            traits = traitsJSON(in: core.directory, step: core.stepModelName)
        }
        Automation.mark("turn-shadow: tier \(String(describing: type(of: model)))\(rung.map { "(\($0))" } ?? "")\(step.map { ", \($0)" } ?? ""), traits \(traits == nil ? "default" : "student")")
        Diag.log("turnmodel", ["tier": String(describing: type(of: model)), "rung": rung ?? "-", "step": step ?? "-", "traits": traits == nil ? "default" : "student", "ok": true])
        return TurnShadow(model: model, traits: traits,
                          meta: ["tier": String(describing: type(of: model)), "rung": rung ?? "-",
                                 "step": step ?? "-", "traits": traits == nil ? "default" : "student"])
    }

    /// The 320 ms turn prefix tier (#132's split tier): a 102 MB layers-0-3 encoder
    /// in `bench-results/prefix/` (where this app's cut tiers already load from),
    /// batched two ears in one cache-aware call. Default on since the 2026-11-05 ruling
    /// (`IDFON_TURN_PREFIX=0` is the kill switch); a set but ambiguous or malformed value,
    /// a missing artifact or a malformed one returns nil and today's cut stays in charge.
    private static func loadPrefixTier() -> TurnShadow? {
        guard TurnPrefix.isEnabled(environment: ProcessInfo.processInfo.environment) else { return nil }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bench = root.appendingPathComponent("bench-results")
        guard let artifact = TurnPrefix.artifact(in: bench) else {
            Automation.mark("turn-shadow: prefix on, no artifact at \(bench.path)/prefix")
            Diag.log("turnmodel", ["tier": "prefix-320", "ok": false, "error": "no prefix artifact"])
            return nil
        }
        let coreml = bench.appendingPathComponent("coreml")
        let student = coreml.appendingPathComponent("StudentStep.mlpackage")
        let teacher = coreml.appendingPathComponent("TygerStep.mlpackage")
        let step = FileManager.default.fileExists(atPath: student.path) ? student : teacher
        do {
            let model = try TurnPrefixModel(artifactURL: artifact, stepURL: step)
            let traits = traitsJSON(in: coreml, step: model.stepModelName)
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
    /// `{"name", "decider": {ep_thr, …}}`) — thresholds are per-model. nil
    /// (teacher step or no file): the bundled live-tuned defaults.
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        capture = TurnCapture(dir: base.appendingPathComponent("Idfon/turn-captures"))
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
        PlaybackBus.add(self)
    }

    /// The mic's samples at the device rate (from the ASR engine's tap; safe
    /// from the audio thread — hops to the work queue).
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

    /// What the agent's side plays (TTS, remote call audio, tones) — the agent
    /// channel. Hop timing pairs 1:1 with the user's in `consume`.
    func audioPlayback(samples: [Float], rate: Double) {
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
        PlaybackBus.remove(self)
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
        let events = engine.feed(userHop: hop, agentHop: agent, mode: mode)
        for e in events where e.kind != "FRAME" {
            let turn = (e.dict["turn_s"] as? Double).map { String(format: "%.2f", $0) } ?? "-"
            let onset = (e.dict["onset_s"] as? Double).map { String(format: "%.2f", $0) } ?? "-"
            Automation.mark("turn-shadow: \(e.kind) frame=\(e.frame) turn_s=\(turn) onset_s=\(onset)")
            onDecision?(e.kind)
        }
    }
}
