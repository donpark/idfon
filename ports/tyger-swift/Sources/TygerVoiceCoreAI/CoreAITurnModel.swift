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
    /// Which step loaded ("tyger_step_…" / "student_step_…") — the decision log
    /// needs it when validating a tier on live calls.
    public let stepModelName: String
    /// Where the tier loaded from (the per-model `student.traits.json` sits here).
    public let directory: URL

    private let stepFn: InferenceFunction
    private let stepInNames: [String]
    private let stepOutNames: [String]
    private let stepInDescs: [String: NDArrayDescriptor]
    private let stepOutDescs: [String: NDArrayDescriptor]

    // The carried GRU state, double-buffered so a step can write gru_state_next
    // while gru_state is still in flight.
    private var gruIn: NDArray
    private var gruOut: NDArray
    /// Floats in the carried state: teacher 3x768, student 2x256.
    private let stateCount: Int

    /// The tier's default artifacts (export_turn.py).
    public convenience init() throws {
        let pkg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try self.init(directory: pkg.appendingPathComponent("bench-results/coreai"))
    }

    public init(directory: URL) throws {
        self.directory = directory
        // Rung selection (2026-10-27): **fp32 by default**, fp16 opt-in via
        // IDFON_TURN_PRECISION=fp16. The fp16 pair (the 2026-10-21 shipping
        // ruling) drifts `p_end` by ~0.03 — enough to shave near-threshold
        // turns below the endpoint gate (corner-case finding 2026-10-27:
        // natural-speed synthetic speech never ended its turn on fp16, and
        // ended it identically to the Python oracle on fp32). The 99.67%
        // decision guard did not catch it because real conversations rarely
        // sit on the margin. fp16 returns as the default when the export
        // keeps the GRU and heads in fp32 (the mixed-precision exemption).
        let forceFP16 = ProcessInfo.processInfo.environment["IDFON_TURN_PRECISION"] == "fp16"
        // Step preference: the distilled student first (StudentStep, 5.3 MB),
        // the teacher (56 MB) as fallback. The encoder is shared. Calibration
        // override `IDFON_TURN_STEP=tyger` pins the teacher (A/B on live calls,
        // and the oracle test's expectations are the teacher's).
        let preferStudent = ProcessInfo.processInfo.environment["IDFON_TURN_STEP"] != "tyger"
        let step = { (rung: String) -> URL? in
            (preferStudent ? ["student_step_\(rung).aimodel", "tyger_step_\(rung).aimodel"]
                           : ["tyger_step_\(rung).aimodel"])
                .map { directory.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        let fp16 = (directory.appendingPathComponent("tyger_encoder_float16.aimodel"), step("float16"))
        let fp32 = (directory.appendingPathComponent("tyger_encoder_float32.aimodel"), step("float32"))
        let have = { (pair: (URL, URL?)) in
            guard let step = pair.1 else { return false }
            return Self.present(pair.0) && Self.present(step)
        }
        // fp32 is the gated reference rung. fp16 is opt-in via
        // IDFON_TURN_PRECISION=fp16 — and the fallback when only the fp16 pair
        // is installed (a side-load), so an install without the fp32 pair
        // never loses the turn model. The ModelStore delivers the fp32 pair.
        let useFP16 = have(fp16) && (forceFP16 || !have(fp32))
        let encURL = useFP16 ? fp16.0 : fp32.0
        guard let stepURL = useFP16 ? fp16.1 : fp32.1 else {
            throw LoadError.missingArtifact("step_float\(useFP16 ? 16 : 32).aimodel")
        }
        self.usesFloat16 = useFP16
        self.stepModelName = stepURL.lastPathComponent
        // The student's GRU: 2 layers x width 256 (ports/tyger-student/model.py).
        self.stateCount = stepURL.lastPathComponent.hasPrefix("student_step_") ? 2 * 256 : 3 * 768
        for u in [encURL, stepURL] where !Self.present(u) {
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

        // gru_state is the carried-state input and gru_state_next its twin output
        // (sized by the loaded tier: teacher 3x768, student 2x256)
        guard let sd = ins["gru_state"], let sn = outs["gru_state_next"] else {
            throw LoadError.missingFunction("gru_state")
        }
        self.gruIn = NDArray(descriptor: sd)
        self.gruOut = NDArray(descriptor: sn)
        self.clearState()
    }

    /// A tier may ship only the AOT container (the source `.aimodel` is 400 MB+
    /// and the loader prefers the compiled child anyway). `prepare` derives the
    /// container path from the source URL, so existence is container-aware here.
    public static func present(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        let compiled = url.deletingLastPathComponent().appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + ".compiled.aimodel")
        let kids = (try? FileManager.default.contentsOfDirectory(
            at: compiled, includingPropertiesForKeys: nil)) ?? []
        return kids.contains { $0.pathExtension == "aimodelc" }
    }

    private static func prepare(_ url: URL, dynamic: Bool) throws -> AIModel {
        // Prefer the AOT-compiled specialization ("<name>.compiled.aimodel", the
        // `xcrun coreai-build compile --preferred-compute gpu --architecture <arch>`
        // output container): loading the source .aimodel makes the runtime compile
        // it per process and leak ANE-compiler scratch (mpsgraph workdirs, ~4 GB
        // per encoder load — the 2026-10-27 disk incident). The loadable unit is
        // the container's per-arch "<name>.<arch>.aimodelc" child, loaded WITHOUT
        // specialization options (options on a compiled asset re-trigger
        // compilation). An arch-mismatched container fails loud — never fall
        // back to the source asset silently, that is the leak.
        let compiled = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".compiled.aimodel")
        let kids = ((try? FileManager.default.contentsOfDirectory(at: compiled, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "aimodelc" }
        if !kids.isEmpty {
            return try runSync { () async throws -> AIModel in
                var firstErr: Error?
                for kid in kids {
                    do { return try await AIModel(contentsOf: kid) } catch { firstErr = firstErr ?? error }
                }
                throw firstErr ?? LoadError.missingArtifact(compiled.path)
            }
        }
        // OS API directly (Apple's PreparedModel wrapper adds nothing we need):
        // GPU posture, reshapes expected for the dynamic-shape encoder.
        return try runSync {
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
        fillNDArray(&gruIn, as: Float.self, count: stateCount) { _ in 0 }
        fillNDArray(&gruOut, as: Float.self, count: stateCount) { _ in 0 }
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
