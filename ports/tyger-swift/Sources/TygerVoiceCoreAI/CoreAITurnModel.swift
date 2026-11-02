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
        /// The AOT package needs a newer OS than this one (see `checkPackage`).
        case incompatiblePackage(String)
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
    /// Static-shape encoders take exactly one 8 s window; a startup window is
    /// padded with silence (the history that does not exist yet). The dynamic
    /// graph takes the true growing window, so the tier marks itself.
    private let padsShortWindows: Bool

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
        // Rung + step selection lives in `select` so the download gate asks the
        // same question the loader will (`loadable`).
        guard let picked = Self.select(in: directory) else {
            throw LoadError.missingArtifact("no loadable tier in \(directory.path)")
        }
        let (encURL, stepURL, useFP16) = (picked.enc, picked.step, picked.fp16)
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
        self.padsShortWindows = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("encoder.static").path)

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
                    do {
                        try Self.checkPackage(kid)
                        return try await AIModel(contentsOf: kid)
                    } catch { firstErr = firstErr ?? error }
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

    /// The oldest OS this tier supports (27.0.x) loads MPSGraph packages up to
    /// this version. A newer package does not raise an error — the Core AI
    /// loader **segfaults** inside MPSGraph (`EXC_BAD_ACCESS` on an llvm-worker
    /// thread, "No valid MPSGraph Package Version found … This OS supports up to
    /// 7.0.80" one line before), which is uncatchable in-process. Assets built
    /// by a newer toolchain (the 2026-11-01 build: `coreai-build 3605.6.3` emits
    /// 7.1.5) therefore crash the app on 27.0.1 unless checked first.
    /// `IDFON_TURN_AOT_MAX` raises the gate for a newer runtime.
    /// The newest MPSGraph package this OS can load. Apple does not expose it,
    /// so it is a per-OS table: 27.0/27.1 cap at 7.0.80, 27.2+ at 7.1.5. A
    /// newer AOT container makes the runtime abort (signal 11), so this guard is
    /// what turns an incompatible tier into a clean fail-open. `IDFON_TURN_AOT_MAX`
    /// overrides it for experiments; update the table when a new OS ships.
    static var maxPackageVersion: [Int] {
        if let forced = packageCeilingOverride { return forced }
        if let forced = ProcessInfo.processInfo.environment["IDFON_TURN_AOT_MAX"], !forced.isEmpty {
            return forced.split(separator: ".").compactMap { Int($0) }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.majorVersion > 27 || (os.majorVersion == 27 && os.minorVersion >= 2) {
            return [7, 1, 5]
        }
        return [7, 0, 80]
    }

    /// Test seam: pin the ceiling without touching the process environment
    /// (`ProcessInfo.environment` is not reliably writable in-process).
    static var packageCeilingOverride: [Int]?

    struct Selection { let enc: URL; let step: URL; let fp16: Bool }

    /// The tier this directory offers: fp32 by default (the gated reference
    /// rung), fp16 opt-in via `IDFON_TURN_PRECISION=fp16` and the fallback when
    /// only the fp16 pair is *installed*; the distilled student step first, the
    /// teacher second (`IDFON_TURN_STEP=tyger` pins the teacher for A/B and for
    /// the oracle test's teacher expectations).
    ///
    /// Two different questions, deliberately:
    /// - *installed* (`present`) decides the rung and the step — a bad student
    ///   step falls back to the teacher step, and fp32 never silently becomes
    ///   fp16 (the 2026-10-27 `p_end` ruling);
    /// - *loadable* (`packageOK`) gates the result: an AOT package newer than the
    ///   OS accepts segfaults the loader, so the tier must be refused instead
    ///   (fall back to CoreML / MLX / classic).
    static func select(in directory: URL) -> Selection? {
        let forceFP16 = ProcessInfo.processInfo.environment["IDFON_TURN_PRECISION"] == "fp16"
        let preferStudent = ProcessInfo.processInfo.environment["IDFON_TURN_STEP"] != "tyger"
        let step = { (rung: String) -> URL? in
            (preferStudent ? ["student_step_\(rung).aimodel", "tyger_step_\(rung).aimodel"]
                           : ["tyger_step_\(rung).aimodel"])
                .map { directory.appendingPathComponent($0) }
                .first { Self.present($0) && Self.packageOK($0) }
        }
        let fp16 = (directory.appendingPathComponent("tyger_encoder_float16.aimodel"), step("float16"))
        let fp32 = (directory.appendingPathComponent("tyger_encoder_float32.aimodel"), step("float32"))
        let present = { (pair: (URL, URL?)) in
            guard let step = pair.1 else { return false }
            return Self.present(pair.0) && Self.present(step)
        }
        let useFP16 = present(fp16) && (forceFP16 || !present(fp32))
        let (enc, s) = useFP16 ? fp16 : fp32
        guard let s, Self.packageOK(enc), Self.packageOK(s) else { return nil }
        return Selection(enc: enc, step: s, fp16: useFP16)
    }

    /// Whether this directory can actually load on this OS (no model load).
    /// The apps use it to pick the tier to download, so a phone never fetches a
    /// Core AI set its runtime would reject (and crash on).
    public static func loadable(in directory: URL) -> Bool {
        select(in: directory) != nil
    }

    /// Whether the loadable tier would use the student step (the apps apply the
    /// student's per-model traits only then).
    public static func studentStep(in directory: URL) -> Bool {
        select(in: directory)?.step.lastPathComponent.hasPrefix("student_step_") ?? false
    }

    /// Whether the tier carries the per-model rules traits with its step.
    public static func hasTraits(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("student.traits.json").path)
    }

    /// Every AOT child of `url` that the OS can load.
    private static func packageOK(_ url: URL) -> Bool {
        let kids = containerKids(url)
        return kids.contains { (try? checkPackage($0)) != nil }
    }

    private static func containerKids(_ url: URL) -> [URL] {
        let compiled = url.deletingLastPathComponent().appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + ".compiled.aimodel")
        return ((try? FileManager.default.contentsOfDirectory(at: compiled, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "aimodelc" }
    }

    /// Refuse to hand the runtime a package newer than the OS can load.
    private static func checkPackage(_ kid: URL) throws {
        let plists = ((try? FileManager.default.subpathsOfDirectory(atPath: kid.path)) ?? [])
            .filter { $0.hasSuffix(".mpsgraphpackage/manifest.plist") }
        for sub in plists {
            let url = kid.appendingPathComponent(sub)
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let versions = (plist["Package Version"] as? [String: Any])?.keys,
                  let newest = versions.compactMap({ Self.version($0) }).max(by: Self.older)
            else { continue }
            if Self.older(Self.maxPackageVersion, newest) {
                throw LoadError.incompatiblePackage(newest.map(String.init).joined(separator: "."))
            }
        }
    }

    private static func version(_ text: String) -> [Int] {
        text.split(separator: ".").compactMap { Int($0) }
    }

    /// a < b, numerically (`7.0.80` > `7.0.63`, `7.1.5` > `7.0.80`).
    private static func older(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public func reset() {
        clearState()
    }

    private func clearState() {
        fillNDArray(&gruIn, as: Float.self, count: stateCount) { _ in 0 }
        fillNDArray(&gruOut, as: Float.self, count: stateCount) { _ in 0 }
    }

    public func encode(_ window: [Float]) -> [[Float]] {
        var audio = window
        if padsShortWindows {
            let full = 8 * MelFeatures.sampleRate
            if audio.count < full {
                audio = [Float](repeating: 0, count: full - audio.count) + audio
            }
        }
        let (frames, _) = MelFeatures.process(audio)
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
