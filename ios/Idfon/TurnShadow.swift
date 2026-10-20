import AVFAudio
import Foundation
import TygerVoice
import TygerVoiceCoreAI

/// Shadow turn-taker (iOS): runs the turn engine beside the text Segmenter and
/// marks its events for a decision-log diff. It changes NO behavior — the
/// segmenter's commit stays authoritative until the diff says otherwise (the
/// swap-over convention; `docs/voice-tyger-option.md` P3).
///
/// Tier: Core AI (iOS 27+, fp32 GPU — the oracle-exact tier) when its
/// `.aimodel`s are side-loaded in `Documents/tyger-models/coreai/`; otherwise
/// CoreML (TygerEncoder fp16 on ANE, TygerEncoderDyn at startup, TygerStep
/// fp32) — the accepted pre-27 iOS tier — from `Documents/tyger-models/`.
/// With no models there the shadow stays off and says so in the Automation log.
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
    /// Agent-channel hops waiting for their user hop (paired 1:1 in consume).
    private var agentHops: [[Float]] = []
    /// Serial, off the audio render thread: inference never runs in a tap callback.
    private let queue = DispatchQueue(label: "idfon.turn-shadow")
    private var mode = "listen"
    /// The active-mode sink (the tyger option): non-FRAME decisions as they
    /// fire. The Automation marks stay either way (the diff log).
    var onDecision: ((String) -> Void)?

    /// nil when no models are available.
    static func start() -> TurnShadow? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tyger-models")
        if #available(iOS 27.0, *),
           let coreai = try? CoreAITurnModel(directory: dir.appendingPathComponent("coreai")) {
            Automation.mark("turn-shadow: tier CoreAI (fp32 GPU)")
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
        tap.onHop = { [weak self] samples in
            self?.consume(samples)
        }
        agentTap.onHop = { [weak self] samples in
            self?.agentHops.append(samples) // already on the serial queue (tap.feed is)
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
        queue.async { self.tap.feed(samples, rate: rate) }
    }

    /// What the playback bus is about to play (TTS + remote call audio) — the
    /// agent channel. Hop timing pairs 1:1 with the user's in `consume`.
    func audioPlayback(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        let rate = buffer.format.sampleRate
        queue.async { self.agentTap.feed(samples, rate: rate) }
    }

    /// "listen" while the caller speaks, "speaking" while the agent plays.
    func setMode(_ mode: String) {
        queue.async { self.mode = mode }
    }

    func stop() {
        AudioIO.shared.removeCaptureObserver(self)
        AudioIO.shared.removePlaybackObserver(self)
        queue.sync {
            engine.reset()
            agentHops.removeAll()
        }
    }

    private func consume(_ hop: [Float]) {
        let agent = agentHops.isEmpty ? [Float](repeating: 0, count: hop.count) : agentHops.removeFirst()
        let events = engine.feed(userHop: hop, agentHop: agent, mode: mode)
        for e in events where e.kind != "FRAME" {
            let turn = (e.dict["turn_s"] as? Double).map { String(format: "%.2f", $0) } ?? "-"
            let onset = (e.dict["onset_s"] as? Double).map { String(format: "%.2f", $0) } ?? "-"
            Automation.mark("turn-shadow: \(e.kind) frame=\(e.frame) turn_s=\(turn) onset_s=\(onset)")
            onDecision?(e.kind)
        }
    }
}
