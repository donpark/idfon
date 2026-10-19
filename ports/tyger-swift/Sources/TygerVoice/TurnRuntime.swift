import Foundation

/// The feed loop: 320 ms hops -> per-frame 8-vectors, with the windows, features
/// and the model calls behind the ``TurnModel`` seam (Core ML on iOS, MLX on mac).
/// Mirrors ReferenceEars.feed exactly (the Python oracle): growing windows to
/// 8 s then sliding; four step calls per hop threading the carried state.
///
/// Rules stay at the seam: the caller supplies `prevState` per frame (its decision
/// state machine owns it) and calls `reset()` wherever the oracle's rules say the
/// heads' context must start over (BARGE/ENDPOINT/mode switch).
public final class TurnRuntime {
    public static let sampleRate = 16000
    public static let hopSamples = 5120 // HOP_FRAMES(4) * 0.08 s * 16 kHz
    public static let windowSamples = 8 * TurnRuntime.sampleRate

    private let model: TurnModel
    private var winUser: [Float] = []
    private var winAgent: [Float] = []

    public init(model: TurnModel) {
        self.model = model
    }

    /// The iOS tier's Core ML models (TygerEncoder fp16 + TygerStep fp32).
    public convenience init(encoderURL: URL, encoderDynURL: URL, stepURL: URL) throws {
        self.init(model: try CoreMLTurnModel(encoderURL: encoderURL, encoderDynURL: encoderDynURL, stepURL: stepURL))
    }

    public func reset() {
        model.reset()
    }

    /// Feed one hop; returns the scored frames' 8-vectors (up to 4, oldest
    /// first). `onFrame` receives each frame's 8-vector, its energy and the
    /// frames left in the hop, right after its step, and returns the prev_state
    /// the NEXT frame's step consumes — the oracle's per-frame rules threading.
    public func feed(
        userHop: [Float], agentHop: [Float], firstState: Int,
        onFrame: (_ frame: Int, _ outs: [Float], _ actDb: Double, _ left: Int) -> Int
    ) -> [[Float]] {
        append(&winUser, userHop)
        append(&winAgent, agentHop)
        let hu = model.encode(winUser)
        let ha = model.encode(winAgent)
        let act = Self.frameEnergy(winUser)
        let n = min(4, hu.count, ha.count, act.count)
        var outs: [[Float]] = []
        var prev = firstState
        for i in 0..<n {
            let out = model.step(
                hu: hu[hu.count - n + i], ha: ha[ha.count - n + i],
                actDb: Double(act[act.count - n + i]), prevState: prev)
            outs.append(out)
            prev = onFrame(outs.count - 1, out, Double(act[act.count - n + i]), n - 1 - i)
        }
        return outs
    }

    /// Feed one hop with a per-frame state lookup and no interleaved rules.
    public func feed(userHop: [Float], agentHop: [Float], prevState: (Int) -> Int) -> [[Float]] {
        feed(userHop: userHop, agentHop: agentHop, firstState: prevState(0)) { i, _, _, _ in
            prevState(i + 1)
        }
    }

    private func append(_ win: inout [Float], _ hop: [Float]) {
        win.append(contentsOf: hop)
        if win.count > Self.windowSamples {
            win.removeFirst(win.count - Self.windowSamples)
        }
    }

    /// Per-80 ms-frame energy in dB — rules.frame_energy's formula, for the step's act input.
    public static func frameEnergy(_ wav: [Float]) -> [Float] {
        let hop = 1280
        let n = wav.count / hop
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        for f in 0..<n {
            var acc: Float = 0
            for i in 0..<hop {
                let x = wav[f * hop + i]
                acc += x * x
            }
            let mean = acc / Float(hop)
            out[f] = 20 * log10f(sqrtf(mean + 1e-12) + 1e-9)
        }
        return out
    }
}
