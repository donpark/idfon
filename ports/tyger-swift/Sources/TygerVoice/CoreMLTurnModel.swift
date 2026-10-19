import CoreML
import Foundation

/// The iOS tier's models (TygerEncoder fp16 on ANE, TygerEncoderDyn at startup,
/// TygerStep fp32) behind the ``TurnModel`` seam.
public final class CoreMLTurnModel: TurnModel {
    private let encFixed: MLModel
    private let encDyn: MLModel
    private let step: MLModel
    private var state: [Float] // the GRU's (3, 1, 768) carried state

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

    public func encode(_ window: [Float]) -> [[Float]] {
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

    public func step(hu: [Float], ha: [Float], actDb: Double, prevState: Int) -> [Float] {
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
}
