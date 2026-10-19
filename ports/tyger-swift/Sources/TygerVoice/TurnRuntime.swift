import CoreML
import Foundation

/// The feed loop: 320 ms hops -> per-frame 8-vectors, with the windows, features,
/// Core ML models and the carried GRU state. Mirrors ReferenceEars.feed exactly
/// (the Python oracle): growing windows to 8 s then sliding; the encoder is the
/// dynamic model while the window is short (the startup contract) and the fp16
/// model at steady state; four `TygerStep` calls per hop threading the state.
///
/// Rules stay at the seam: the caller supplies `prevState` per frame (its decision
/// state machine owns it) and calls `reset()` wherever the oracle's rules say the
/// heads' context must start over (BARGE/ENDPOINT/mode switch).
public final class TurnRuntime {
    public static let sampleRate = 16000
    public static let hopSamples = 5120 // HOP_FRAMES(4) * 0.08 s * 16 kHz
    public static let windowSamples = 8 * TurnRuntime.sampleRate

    private let encFixed: MLModel
    private let encDyn: MLModel
    private let step: MLModel
    private var state: [Float] // the GRU's (3, 1, 768) carried state
    private var winUser: [Float] = []
    private var winAgent: [Float] = []

    private static func load(_ url: URL, units: MLComputeUnits) throws -> MLModel {
        // mlpackages load compiled; the apps should precompile and pass the .mlmodelc
        let compiled = try MLModel.compileModel(at: url)
        let c = MLModelConfiguration()
        c.computeUnits = units
        return try MLModel(contentsOf: compiled, configuration: c)
    }

    public init(encoderURL: URL, encoderDynURL: URL, stepURL: URL) throws {
        self.encFixed = try Self.load(encoderURL, units: .all)
        self.encDyn = try Self.load(encoderDynURL, units: .cpuOnly) // rel_shift reshape fails MPS inference
        self.step = try Self.load(stepURL, units: .all)
        self.state = [Float](repeating: 0, count: 3 * 768)
    }

    public func reset() {
        state = [Float](repeating: 0, count: 3 * 768)
    }

    /// Feed one hop; returns the scored frames' 8-vectors (up to 4, oldest first).
    /// `prevState` gets the caller's state for each frame (the oracle threads it
    /// through its rules between frames of the same hop).
    public func feed(userHop: [Float], agentHop: [Float], prevState: (Int) -> Int) -> [[Float]] {
        append(&winUser, userHop)
        append(&winAgent, agentHop)
        let hu = encode(winUser)
        let ha = encode(winAgent)
        let act = Self.frameEnergy(winUser)
        let n = min(4, hu.count, ha.count, act.count)
        var outs: [[Float]] = []
        for i in 0..<n {
            let ui = hu.count - n + i
            let ai = ha.count - n + i
            let actIdx = act.count - n + i
            outs.append(stepFrame(hu: hu[ui], ha: ha[ai], actDb: Double(act[actIdx]), prevState: prevState(i)))
        }
        return outs
    }

    private func append(_ win: inout [Float], _ hop: [Float]) {
        win.append(contentsOf: hop)
        if win.count > Self.windowSamples {
            win.removeFirst(win.count - Self.windowSamples)
        }
    }

    private func encode(_ window: [Float]) -> [[Float]] {
        let (frames, _) = MelFeatures.process(window)
        let t = frames.count
        var flat = [Float](repeating: 0, count: t * MelFeatures.nMels)
        for (i, row) in frames.enumerated() {
            flat.replaceSubrange((i * MelFeatures.nMels)..<((i + 1) * MelFeatures.nMels), with: row)
        }
        let model = t == 801 ? encFixed : encDyn // 801 mel frames = the full 8 s window
        let arr = try! MLMultiArray(shape: [1, NSNumber(value: t), NSNumber(value: MelFeatures.nMels)] as [NSNumber], dataType: .float32)
        for (i, v) in flat.enumerated() {
            arr[i] = NSNumber(value: v)
        }
        let out = try! model.prediction(from: try! MLDictionaryFeatureProvider(dictionary: ["feats": arr]))
        let hidden = out.featureValue(for: out.featureNames.first!)!.multiArrayValue!
        var rows: [[Float]] = []
        for f in 0..<(hidden.count / 1024) { // encoder frames = mel frames / 8
            var row = [Float](repeating: 0, count: 1024)
            for k in 0..<1024 {
                row[k] = hidden[f * 1024 + k].floatValue
            }
            rows.append(row)
        }
        return rows
    }

    private func stepFrame(hu: [Float], ha: [Float], actDb: Double, prevState: Int) -> [Float] {
        func arr(_ shape: [NSNumber], _ fill: [Float]) -> MLMultiArray {
            let a = try! MLMultiArray(shape: shape, dataType: .float32)
            for (i, v) in fill.enumerated() {
                a[i] = NSNumber(value: v)
            }
            return a
        }
        let st = arr([3, 1, 768], state)
        let dict: [String: Any] = [
            "hu": arr([1, 1, 1024], hu),
            "ha": arr([1, 1, 1024], ha),
            "act_db": arr([1, 1], [Float(actDb)]),
            "prev_state": { let a = try! MLMultiArray(shape: [1, 1], dataType: .int32); a[0] = NSNumber(value: prevState); return a }(),
            "state_workaround": st,
        ]
        let provider = try! MLDictionaryFeatureProvider(dictionary: dict)
        let out = try! step.prediction(from: provider)
        // bind outputs by shape: the 8-vector vs the (3,1,768) state — survives renames
        var eight: [Float] = []
        for name in out.featureNames {
            guard let m = out.featureValue(for: name)?.multiArrayValue else { continue }
            if m.count == 8 {
                for i in 0..<8 {
                    eight.append(m[i].floatValue)
                }
            } else if m.count == 3 * 768 {
                for i in 0..<(3 * 768) {
                    state[i] = m[i].floatValue
                }
            }
        }
        return eight
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
