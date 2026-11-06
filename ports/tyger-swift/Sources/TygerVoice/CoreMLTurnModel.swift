import CoreML
import Foundation

/// The iOS tier's models (TygerEncoder fp16 on ANE, TygerEncoderDyn at startup,
/// TygerStep or the distilled StudentStep fp32) behind the ``TurnModel`` seam.
public final class CoreMLTurnModel: TurnModel {
    public enum LoadError: Error { case noStateInput }

    private let encFixed: MLModel
    private let encDyn: MLModel
    private let step: CoreMLStep
    /// Which step loaded ("TygerStep.mlpackage" / "StudentStep.mlpackage") — the
    /// decision log needs it when validating a tier on live calls.
    public var stepModelName: String { step.modelName }

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
        do {
            self.step = try CoreMLStep(stepURL: stepURL)
        } catch CoreMLStep.LoadError.noStateInput {
            throw LoadError.noStateInput
        }
    }

    public func reset() {
        step.reset()
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
        step.step(hu: hu, ha: ha, actDb: actDb, prevState: prevState)
    }
}
