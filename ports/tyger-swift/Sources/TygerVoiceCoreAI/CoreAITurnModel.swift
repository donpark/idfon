import CoreAI
import Dispatch
import Foundation
import TygerVoice

/// The OS 27+ tier: the Core AI `.aimodel` chain (ports/tyger-coreai/export_turn.py)
/// behind the ``TurnModel`` seam. Posture: GPU (the NE compile falls back and the
/// CPU specialization fails on the step graph — see ports/tyger-coreai/README.md),
/// fp32 by default (the gated reference tier; fp16 is a later rung).
///
/// The runtime leaks ~1 IOSurface per `run` call on the Python binding (~8-9k
/// calls until a fatal allocation error). Whether this Swift path leaks the same
/// way is exactly what CoreAISoakTests measures — do not trust long calls until
/// it passes.
@available(macOS 27.0, iOS 27.0, *)
public final class CoreAITurnModel: TurnModel {
    public enum LoadError: Error {
        case missingFunction(String)
        case missingArtifact(String)
    }

    private let encFn: InferenceFunction
    private let encInName: String
    private let encOutName: String
    private let encInDesc: NDArrayDescriptor
    private let encOutDesc: NDArrayDescriptor

    /// Which rung loaded: the shipping fp16 pair when present, else the fp32
    /// exact tier (acceptance envelopes differ — see CoreAISoakTests).
    public let usesFloat16: Bool

    private let stepFn: InferenceFunction
    private let stepInNames: [String]
    private let stepOutNames: [String]
    private let stepInDescs: [String: NDArrayDescriptor]
    private let stepOutDescs: [String: NDArrayDescriptor]

    // The carried GRU state (3, 1, 768), double-buffered so a step can write
    // gru_state_next while gru_state is still in flight.
    private var gruIn: NDArray
    private var gruOut: NDArray

    /// The tier's default artifacts (export_turn.py).
    public convenience init() throws {
        let pkg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try self.init(directory: pkg.appendingPathComponent("bench-results/coreai"))
    }

    public init(directory: URL) throws {
        // The shipping rung is **fp16** (2026-10-21 decision; the parity7 guard:
        // 99.67% aligned ±2 frames, 4 boundary flips in 917, half the fp32
        // size). fp32 stays the exact tier and the fallback when the fp16 pair
        // is absent.
        let fp16 = (directory.appendingPathComponent("tyger_encoder_float16.aimodel"),
                    directory.appendingPathComponent("tyger_step_float16.aimodel"))
        let fp32 = (directory.appendingPathComponent("tyger_encoder_float32.aimodel"),
                    directory.appendingPathComponent("tyger_step_float32.aimodel"))
        let hasFP16 = FileManager.default.fileExists(atPath: fp16.0.path)
            && FileManager.default.fileExists(atPath: fp16.1.path)
        let (encURL, stepURL) = hasFP16 ? fp16 : fp32
        self.usesFloat16 = hasFP16
        for u in [encURL, stepURL] where !FileManager.default.fileExists(atPath: u.path) {
            throw LoadError.missingArtifact(u.lastPathComponent)
        }
        let encModel = try Self.prepare(encURL, dynamic: true)
        let stepModel = try Self.prepare(stepURL, dynamic: false)

        guard let encDesc = encModel.functionDescriptor(for: "main"),
              let encFn = try encModel.loadFunction(named: "main") else {
            throw LoadError.missingFunction("encoder main")
        }
        self.encFn = encFn
        self.encInName = encDesc.inputNames[0]
        self.encOutName = encDesc.outputNames[0]
        guard case .ndArray(let d) = encDesc.inputDescriptor(of: encInName),
              case .ndArray(let o) = encDesc.outputDescriptor(of: encOutName) else {
            throw LoadError.missingFunction("encoder descriptors")
        }
        self.encInDesc = d
        self.encOutDesc = o

        guard let stepDesc = stepModel.functionDescriptor(for: "main"),
              let stepFn = try stepModel.loadFunction(named: "main") else {
            throw LoadError.missingFunction("step main")
        }
        self.stepFn = stepFn
        self.stepInNames = stepDesc.inputNames
        self.stepOutNames = stepDesc.outputNames
        var ins: [String: NDArrayDescriptor] = [:]
        for n in stepDesc.inputNames {
            if case .ndArray(let d) = stepDesc.inputDescriptor(of: n) { ins[n] = d }
        }
        var outs: [String: NDArrayDescriptor] = [:]
        for n in stepDesc.outputNames {
            if case .ndArray(let d) = stepDesc.outputDescriptor(of: n) { outs[n] = d }
        }
        self.stepInDescs = ins
        self.stepOutDescs = outs

        // gru_state is the (3, 1, 768) input and gru_state_next its twin output
        guard let sd = ins["gru_state"], let sn = outs["gru_state_next"] else {
            throw LoadError.missingFunction("gru_state")
        }
        self.gruIn = NDArray(descriptor: sd)
        self.gruOut = NDArray(descriptor: sn)
        self.clearState()
    }

    private static func prepare(_ url: URL, dynamic: Bool) throws -> AIModel {
        // OS API directly (Apple's PreparedModel wrapper adds nothing we need):
        // GPU posture, reshapes expected for the dynamic-shape encoder.
        try runSync {
            var opts = SpecializationOptions(preferredComputeUnitKind: .gpu)
            // LANDMINE: expectFrequentReshapes=true CORRUPTS this dynamic model's GPU
            // execution (max|Δ| ~10 on hidden vs the same asset in Python; exact
            // with it off). Apple's dynamic-model guidance is wrong for this graph.
            opts.expectFrequentReshapes = false
            return try await AIModel(contentsOf: url, options: opts)
        }
    }

    public func reset() {
        clearState()
    }

    private func clearState() {
        fillNDArray(&gruIn, as: Float.self, count: 3 * 768) { _ in 0 }
        fillNDArray(&gruOut, as: Float.self, count: 3 * 768) { _ in 0 }
    }

    public func encode(_ window: [Float]) -> [[Float]] {
        let (frames, _) = MelFeatures.process(window)
        let t = frames.count
        guard t > 0 else { return [] }
        // mel lengths are 8k-7; encoder frames = (T + 7) / 8 exactly
        let nOut = (t + 7) / 8
        do {
            return try runSync {
                var mel = NDArray(descriptor: self.encInDesc.resolvingDynamicDimensions([1, t, 128]))
                var i = 0
                fillNDArray(&mel, as: Float.self, count: t * MelFeatures.nMels) { _ in
                    defer { i += 1 }
                    return frames[i / MelFeatures.nMels][i % MelFeatures.nMels]
                }
                var hidden = NDArray(descriptor: self.encOutDesc.resolvingDynamicDimensions([1, nOut, 1024]))
                var outs = InferenceFunction.MutableViews()
                outs.insert(&hidden, for: self.encOutName)
                _ = try await self.encFn.run(
                    inputs: [self.encInName: mel], states: .init(), outputViews: consume outs)
                let rows = Self.read(hidden, nOut * 1024).chunked(into: 1024)
                if ProcessInfo.processInfo.environment["COREAI_DUMP"] != nil {
                    let melSeen = Self.read(mel, t * MelFeatures.nMels)
                    let mel2 = (0..<t).map { Array(melSeen[$0 * MelFeatures.nMels..<($0 + 1) * MelFeatures.nMels]) }
                    let melTxt = mel2.map { $0.map { String($0) }.joined(separator: ",") }.joined(separator: ";")
                    let hidTxt = rows.map { $0.map { String($0) }.joined(separator: ",") }.joined(separator: ";")
                    try? ("\(t)\n" + melTxt + "\n" + hidTxt).write(
                        toFile: "/tmp/swift-enc.txt", atomically: true, encoding: .utf8)
                }
                return rows
            }
        } catch {
            return []
        }
    }

    public func step(hu: [Float], ha: [Float], actDb: Double, prevState: Int) -> [Float] {
        do {
            return try runSync {
                var feeds: [String: NDArray] = [:]
                for name in self.stepInNames {
                    guard let d = self.stepInDescs[name] else { continue }
                    var a = NDArray(descriptor: d)
                    switch name {
                    case "hidden_user":
                        fillNDArray(&a, as: Float.self, with: hu)
                    case "hidden_agent":
                        fillNDArray(&a, as: Float.self, with: ha)
                    case "energy_db":
                        fillNDArray(&a, as: Float.self, with: [Float(actDb)])
                    case "state_id":
                        fillNDArray(&a, as: Int32.self, with: [Int32(prevState)])
                    case "gru_state":
                        a = self.gruIn
                    default:
                        break
                    }
                    feeds[name] = a
                }
                var outVec = NDArray(descriptor: self.stepOutDescs["decision_vector"]!)
                var outState = self.gruOut
                var outs = InferenceFunction.MutableViews()
                outs.insert(&outVec, for: "decision_vector")
                outs.insert(&outState, for: "gru_state_next")
                _ = try await self.stepFn.run(
                    inputs: feeds, states: .init(), outputViews: consume outs)
                self.gruOut = outState
                swap(&self.gruIn, &self.gruOut) // next call steps from the new state
                return Self.read(outVec, 8)
            }
        } catch {
            return [Float](repeating: 0, count: 8)
        }
    }

    private static func read(_ a: NDArray, _ count: Int) -> [Float] {
        readNDArray(a, as: Float.self, count: count)
    }
}

/// Bridge the sync ``TurnModel`` seam to Core AI's async API. Runs on a
/// detached task and blocks the caller's thread (the app feeds hops from a
/// serial background queue — see TurnShadow — so blocking is safe).
@available(macOS 27.0, iOS 27.0, *)
func runSync<T>(_ work: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task.detached {
        do {
            result = .success(try await work())
        } catch {
            result = .failure(error)
        }
        sem.signal()
    }
    sem.wait()
    guard let result else {
        fatalError("runSync: the work never completed")
    }
    return try result.get()
}

@available(macOS 27.0, iOS 27.0, *)
private extension Array {
    func chunked(into n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map {
            Array(self[$0..<Swift.min($0 + n, count)])
        }
    }
}
