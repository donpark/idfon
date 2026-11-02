import CoreML
import Foundation

/// The iOS tier's models (TygerEncoder fp16 on ANE, TygerEncoderDyn at startup,
/// TygerStep or the distilled StudentStep fp32) behind the ``TurnModel`` seam.
public final class CoreMLTurnModel: TurnModel {
    public enum LoadError: Error { case noStateInput }

    private let encFixed: MLModel
    private let encDyn: MLModel
    private let step: MLModel
    /// The carried GRU state: teacher (3, 1, 768) or student (2, 1, 256).
    private let stateShape: [NSNumber]
    private let stateInputName: String
    private var state: [Float]
    /// Which step loaded ("TygerStep.mlpackage" / "StudentStep.mlpackage") — the
    /// decision log needs it when validating a tier on live calls.
    public let stepModelName: String

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
        let stepModel = try Self.load(stepURL, units: .all)
        self.step = stepModel
        // Bind the state feature by shape, not name: toolchains rename `state`
        // (`state_workaround` in every shipped package) and the two models
        // differ only in its shape — (3,1,768) teacher, (2,1,256) student.
        // `hu`/`ha` are rank 3 too (1,1,1024), hence the width guard.
        let stateInput = stepModel.modelDescription.inputDescriptionsByName.first {
            let shape = $0.value.multiArrayConstraint?.shape.map { $0.intValue } ?? []
            return shape.count == 3 && shape[2] != 1024
        }
        guard let stateInput, let shape = stateInput.value.multiArrayConstraint?.shape else {
            throw LoadError.noStateInput
        }
        self.stateInputName = stateInput.key
        self.stateShape = shape
        self.stepModelName = stepURL.lastPathComponent
        self.state = [Float](repeating: 0, count: shape.reduce(1) { $0 * $1.intValue })
    }

    public func reset() {
        state = [Float](repeating: 0, count: state.count)
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
        var dict: [String: Any] = [
            "hu": arr([1, 1, 1024], hu),
            "ha": arr([1, 1, 1024], ha),
            "act_db": arr([1, 1], [Float(actDb)]),
            "prev_state": { let a = try! MLMultiArray(shape: [1, 1], dataType: .int32); a[0] = NSNumber(value: prevState); return a }(),
        ]
        dict[stateInputName] = arr(stateShape, state)
        let provider = try! MLDictionaryFeatureProvider(dictionary: dict)
        let out = try! step.prediction(from: provider)
        // bind outputs by shape: the 8-vector vs the carried state — survives renames
        var eight: [Float] = []
        for name in out.featureNames {
            guard let m = out.featureValue(for: name)?.multiArrayValue else { continue }
            if m.count == 8 {
                for i in 0..<8 {
                    eight.append(m[i].floatValue)
                }
            } else if m.count == state.count {
                for i in 0..<state.count {
                    state[i] = m[i].floatValue
                }
            }
        }
        return eight
    }
}
