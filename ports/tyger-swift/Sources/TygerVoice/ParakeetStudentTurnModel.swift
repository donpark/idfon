import CoreML
import Foundation

/// The path-C tier behind ``TurnModel``: the shipped Parakeet Redux encoder as the
/// feature tap + the distilled student step (14M heads on Parakeet features).
///
/// Tap contract (matches the training harness exactly, `pathc_common.Tap`):
/// each `encode` call right-aligns the window in a 15 s zero-padded buffer,
/// runs Preprocessor -> Encoder, and returns the 188 rows (12.5 Hz, 1024 wide).
/// Rows near the end are "now"; `TurnRuntime` consumes the window's last rows,
/// which pair 1:1 with its per-frame energies.
///
/// Compute units: BOTH encoder models on CPU. Measured (tap_check.swift):
/// ANE/GPU drifts from the training features (max |Δ| 0.086) and is not faster
/// (steady 132 ms vs 85 ms per encode).
public final class ParakeetStudentTurnModel: TurnModel {
    private let pre: MLModel
    private let enc: MLModel
    private let step: MLModel
    private var state: [Float] // the GRU's (3, 1, 768) carried state

    private static let totalSamples = 240_000 // the encoder's fixed 15 s input
    private static let melFrames = 1501
    private static let rows = 188 // ceil(1501 / 8)

    /// - Parameters:
    ///   - preprocessorURL / encoderURL: the shipped `Preprocessor.mlmodelc` /
    ///     `Encoder.mlmodelc` bundles (the FluidAudio ASR cache has them).
    ///   - stepURL: the distilled student step (`mlpackage`, compiled on load).
    public init(preprocessorURL: URL, encoderURL: URL, stepURL: URL) throws {
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        self.pre = try MLModel(contentsOf: Self.compile(preprocessorURL), configuration: cpu)
        self.enc = try MLModel(contentsOf: Self.compile(encoderURL), configuration: cpu)
        let any = MLModelConfiguration()
        self.step = try MLModel(contentsOf: Self.compile(stepURL), configuration: any)
        self.state = [Float](repeating: 0, count: 3 * 768)
    }

    private static func compile(_ url: URL) throws -> URL {
        url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
    }

    public func reset() {
        state = [Float](repeating: 0, count: 3 * 768)
    }

    public func encode(_ window: [Float]) -> [[Float]] {
        let w = Array(window.suffix(Self.totalSamples))
        let audio = try! MLMultiArray(shape: [1, NSNumber(value: Self.totalSamples)], dataType: .float32)
        audio.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer, _) in
            let f = ptr.bindMemory(to: Float.self)
            for i in 0..<Self.totalSamples { f[i] = 0 }
            for i in 0..<w.count { f[Self.totalSamples - w.count + i] = w[i] }
        }
        let audioLength = try! MLMultiArray(shape: [1], dataType: .int32)
        audioLength[0] = NSNumber(value: Int32(Self.totalSamples))
        let mel = try! pre.prediction(from: try! MLDictionaryFeatureProvider(
            dictionary: ["audio_signal": MLFeatureValue(multiArray: audio),
                         "audio_length": MLFeatureValue(multiArray: audioLength)]))
            .featureValue(for: "mel")!.multiArrayValue!
        let melLength = try! MLMultiArray(shape: [1], dataType: .int32)
        melLength[0] = NSNumber(value: Int32(Self.melFrames))
        let out = try! enc.prediction(from: try! MLDictionaryFeatureProvider(
            dictionary: ["mel": MLFeatureValue(multiArray: mel),
                         "mel_length": MLFeatureValue(multiArray: melLength)]))
        let hidden = out.featureValue(for: "encoder")!.multiArrayValue! // (1, 1024, 188)
        var rows: [[Float]] = []
        hidden.withUnsafeBufferPointer(ofType: Float.self) { buf in
            for r in 0..<Self.rows {
                var row = [Float](repeating: 0, count: 1024)
                for k in 0..<1024 { row[k] = buf[k * Self.rows + r] }
                rows.append(row)
            }
        }
        return rows
    }

    public func step(hu: [Float], ha: [Float], actDb: Double, prevState: Int) -> [Float] {
        func arr1x1(_ v: Float) -> MLMultiArray {
            let a = try! MLMultiArray(shape: [1, 1], dataType: .float32)
            a[0] = NSNumber(value: v)
            return a
        }
        let huA = try! MLMultiArray(shape: [1, 1, NSNumber(value: 1024)], dataType: .float32)
        for (i, v) in hu.enumerated() { huA[i] = NSNumber(value: v) }
        let haA = try! MLMultiArray(shape: [1, 1, NSNumber(value: 1024)], dataType: .float32)
        for (i, v) in ha.enumerated() { haA[i] = NSNumber(value: v) }
        let prev = try! MLMultiArray(shape: [1, 1], dataType: .int32)
        prev[0] = NSNumber(value: Int32(prevState))
        let st = try! MLMultiArray(shape: [3, 1, NSNumber(value: 768)], dataType: .float32)
        for (i, v) in state.enumerated() { st[i] = NSNumber(value: v) }

        let out = try! step.prediction(from: try! MLDictionaryFeatureProvider(dictionary: [
            "hu": MLFeatureValue(multiArray: huA),
            "ha": MLFeatureValue(multiArray: haA),
            "act_db": MLFeatureValue(multiArray: arr1x1(Float(actDb))),
            "prev_state": MLFeatureValue(multiArray: prev),
            "state_workaround": MLFeatureValue(multiArray: st), // "state" is renamed at conversion
        ]))
        var decision = [Float](repeating: 0, count: 8)
        for name in out.featureNames {
            guard let a = out.featureValue(for: name)?.multiArrayValue else { continue }
            if a.shape.last == 8 {
                for k in 0..<8 { decision[k] = a[k].floatValue }
            } else if a.count == 3 * 768 {
                for i in 0..<(3 * 768) { state[i] = a[i].floatValue }
            }
        }
        return decision
    }
}
