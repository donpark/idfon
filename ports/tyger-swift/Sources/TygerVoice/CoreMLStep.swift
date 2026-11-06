import CoreML
import Foundation

/// The step model (teacher `TygerStep` / distilled `StudentStep`) with its carried
/// GRU state, shared by the windowed cut tier (``CoreMLTurnModel``) and the
/// streaming prefix tier (``TurnPrefixModel``). One instance == one ears stream's
/// head context; `reset()` is the rules' reset point.
final class CoreMLStep {
    enum LoadError: Error { case noStateInput }

    private let model: MLModel
    /// The carried GRU state: teacher (3, 1, 768) or student (2, 1, 256).
    private let stateShape: [NSNumber]
    private let stateInputName: String
    private var state: [Float]
    let modelName: String

    init(stepURL: URL, units: MLComputeUnits = .all) throws {
        let compiled = try MLModel.compileModel(at: stepURL)
        let config = MLModelConfiguration()
        config.computeUnits = units
        let model = try MLModel(contentsOf: compiled, configuration: config)
        // Bind the state feature by shape, not name: toolchains rename `state`
        // (`state_workaround` in every shipped package) and the two models
        // differ only in its shape — (3,1,768) teacher, (2,1,256) student.
        // `hu`/`ha` are rank 3 too (1,1,1024), hence the width guard.
        let stateInput = model.modelDescription.inputDescriptionsByName.first {
            let shape = $0.value.multiArrayConstraint?.shape.map { $0.intValue } ?? []
            return shape.count == 3 && shape[2] != 1024
        }
        guard let stateInput, let shape = stateInput.value.multiArrayConstraint?.shape else {
            throw LoadError.noStateInput
        }
        self.model = model
        self.stateInputName = stateInput.key
        self.stateShape = shape
        self.modelName = stepURL.lastPathComponent
        self.state = [Float](repeating: 0, count: shape.reduce(1) { $0 * $1.intValue })
    }

    func reset() {
        state = [Float](repeating: 0, count: state.count)
    }

    func step(hu: [Float], ha: [Float], actDb: Double, prevState: Int) -> [Float] {
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
        let out = try! model.prediction(from: provider)
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
