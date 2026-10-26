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
/// Tier: Core AI on macOS 27+ (oracle-exact), MLX below.
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
        var model: TurnModel?
        // Calibration override: IDFON_TURN_TIER=coreai|mlx picks the tier.
        let tier = ProcessInfo.processInfo.environment["IDFON_TURN_TIER"]
        if tier != "mlx", #available(macOS 27.0, *) {
            model = model ?? (try? CoreAITurnModel()) // the OS 27+ tier (GPU, oracle-exact)
        }
        if model == nil {
            model = try? MlxTurnModel() // legacy macOS 14-26 tier
        }
        guard let model else {
            Automation.mark("turn-shadow: no turn model available")
            return nil
        }
        Automation.mark("turn-shadow: tier \(String(describing: type(of: model)))")
        return TurnShadow(model: model)
    }

    private init(model: TurnModel) {
        engine = TurnEngine(model: model, rules: TurnRulesCABI())
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
