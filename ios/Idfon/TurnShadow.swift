import AVFAudio
import Foundation
import TygerVoice

/// Shadow turn-taker (iOS): runs the turn engine beside the text Segmenter and
/// marks its events for a decision-log diff. It changes NO behavior — the
/// segmenter's commit stays authoritative until the diff says otherwise (the
/// swap-over convention; `docs/voice-tyger-option.md` P3).
///
/// Tier: CoreML (TygerEncoder fp16 on ANE, TygerEncoderDyn at startup, TygerStep
/// fp32) — the accepted iOS tier. Models are side-loaded for development into
/// `Documents/tyger-models/` (`devicectl device copy to`); with no models there
/// the shadow stays off and says so in the Automation log.
///
/// Phase-1 limitation (same as the mac's TurnShadow): no TTS PCM tap exists yet,
/// so the agent channel is silence — BARGE events are unreliable and the 8 s
/// window misses the agent's preceding utterance. Upgrade when a TTS tap lands.
final class TurnShadow: AudioCaptureObserver {
    private let engine: TurnEngine
    private let tap: TurnTap
    /// Serial, off the audio render thread: inference never runs in a tap callback.
    private let queue = DispatchQueue(label: "idfon.turn-shadow")
    private var mode = "listen"

    /// nil when no models are available.
    static func start() -> TurnShadow? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tyger-models")
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
        tap.onHop = { [weak self] samples in
            self?.consume(samples)
        }
        AudioIO.shared.addCaptureObserver(self)
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

    /// "listen" while the caller speaks, "speaking" while the agent plays.
    func setMode(_ mode: String) {
        queue.async { self.mode = mode }
    }

    func stop() {
        AudioIO.shared.removeCaptureObserver(self)
        queue.sync { engine.reset() }
    }

    private func consume(_ hop: [Float]) {
        let zeros = [Float](repeating: 0, count: hop.count)
        let events = engine.feed(userHop: hop, agentHop: zeros, mode: mode)
        for e in events where e.kind != "FRAME" {
            let turn = (e.dict["turn_s"] as? Double).map { String(format: "%.2f", $0) } ?? "-"
            let onset = (e.dict["onset_s"] as? Double).map { String(format: "%.2f", $0) } ?? "-"
            Automation.mark("turn-shadow: \(e.kind) frame=\(e.frame) turn_s=\(turn) onset_s=\(onset)")
        }
    }
}
