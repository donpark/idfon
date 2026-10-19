import Foundation
import TygerVoice
import TygerVoiceMLX

/// Shadow turn-taker: runs the mac tier's turn engine beside the text
/// `Segmenter` and marks its events for a decision-log diff. It changes NO
/// behavior — the segmenter's 1.2 s no-change commit stays authoritative until
/// the diff says otherwise (the swap-over convention).
///
/// Phase-1 limitations (shortcut: the TTS PCM seam does not exist yet, so the
/// agent channel is silence — BARGE events are unreliable and 8 s windows miss
/// the agent's preceding utterance; upgrade when a TTS tap lands):
/// the user channel is real mic audio at 16 kHz; the agent channel is zeros.
final class TurnShadow {
    private let engine: TurnEngine
    private let tap: TurnTap
    /// Serial, off the audio render thread: the model's inference never runs
    /// inside a tap callback.
    private let queue = DispatchQueue(label: "idfon.turn-shadow")
    private var mode = "listen"

    /// nil when the mac tier's weights are not exported yet.
    static func start() -> TurnShadow? {
        guard let model = try? MlxTurnModel() else {
            Automation.mark("turn-shadow: MLX weights missing (ports/tyger-mlx/export_swift.py)")
            return nil
        }
        return TurnShadow(model: model)
    }

    private init(model: TurnModel) {
        engine = TurnEngine(model: model, rules: TurnRulesCABI())
        tap = TurnTap(hopSize: TurnRuntime.hopSamples)
        tap.onHop = { [weak self] samples in
            self?.consume(samples)
        }
    }

    /// The mic's samples at the device rate (from the ASR engine's tap; safe
    /// from the audio thread — hops to the work queue).
    func feed(_ samples: [Float], rate: Double) {
        queue.async { self.tap.feed(samples, rate: rate) }
    }

    /// "listen" while the caller speaks, "speaking" while the agent plays.
    func setMode(_ mode: String) {
        queue.async { self.mode = mode }
    }

    func stop() {
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
