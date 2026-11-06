import CoreML
import Foundation

/// The 320 ms turn prefix tier: layers 0-3 of the shipping encoder with `tap_l4`
/// and the caches as its only value outputs (`export_asr_tap.py --prefix-only
/// --depth 4 --chunk-ms 320`). Both ears are one batched prediction with two
/// independent cache sets; the ASR keeps its own 560 ms full encoder and sees
/// none of this.
///
/// Everything the tier needs is read from the artifact itself — cache depth, layer
/// count, mel framing, tap rows per chunk — never from the shipping ASR metadata
/// (`cache_channel_shape[2]` was 70 in the 56/0 bundle beside a 42-deep artifact).
/// Loading fails closed: ``TurnShadow`` falls back to today's cut on any error.
///
/// `docs/voice-tyger-ondevice.md` § "Ruling: the split tier is what ships",
/// § "The 320 refit and a turn-purpose prefix", § "Batched ears and the silent-ear
/// cache on the 320 ms prefix".
public final class TurnPrefixModel: BatchedEarModel {
    public enum LoadError: Error, CustomStringConvertible {
        case malformedArtifact(String)
        case cadenceMismatch(totalMel: Int, tapRows: Int)
        case cacheDepthMismatch(artifact: Int, declared: Int)
        case noPromptID

        public var description: String {
            switch self {
            case .malformedArtifact(let why): return "malformed prefix artifact: \(why)"
            case .cadenceMismatch(let mel, let rows):
                return "prefix artifact is not a 320 ms hop: \(mel) mel frames, \(rows) tap rows"
            case .cacheDepthMismatch(let artifact, let declared):
                return "cache depth \(declared) in metadata.json, \(artifact) in the artifact"
            case .noPromptID:
                return "prompt_id is not declared by the artifact (metadata.json)"
            }
        }
    }

    /// What the artifact declares, validated against this runtime's hop.
    public struct Shape: Equatable {
        /// Batched slots (2 = one mic + one playback ear).
        public let batch: Int
        /// Encoder layers in the graph (4 for the turn prefix, 24 for a full encoder).
        public let layers: Int
        /// `cache_channel_shape[2]` — 42 for the shipping 42/13 pass.
        public let cacheDepth: Int
        /// `mel` input's frame count (41 = 32 new + 9 pre-encode context).
        public let totalMelFrames: Int
        /// New mel rows per hop: the runtime's 320 ms hop / 10 ms mel hop.
        public let newMelFrames: Int
        /// Tap rows released per hop (`tap_l4`'s last dimension).
        public let tapRowsPerChunk: Int
        /// The encoder width (1024).
        public let hidden: Int

        public var preEncodeMelFrames: Int { totalMelFrames - newMelFrames }
        public var cacheChannelShape: [Int] { [batch, layers, cacheDepth, hidden] }
        public var cacheTimeShape: [Int] { [batch, layers, hidden, 8] }
    }

    public let shape: Shape
    /// The cache depth the graph declares — asserted at load against the sidecar.
    public var artifactCacheDepth: Int { shape.cacheDepth }
    /// Where `prompt_id` came from: the sidecar (`metadata.json`) or the caller.
    public let promptID: Int
    /// Which step model loaded — the decision log's tier record and traits lookup.
    public var stepModelName: String { step.modelName }

    private let model: MLModel
    private let step: CoreMLStep
    private var melStreams: [StreamingMel]
    private var cacheChannel: MLMultiArray
    private var cacheTime: MLMultiArray
    private var cacheLen: MLMultiArray
    /// The export's example input and the manager's seed: one filled cache slot, so
    /// the first chunk's mask drops every unfilled slot (`kv >= C - cl`).
    private static let initialCacheLength: Int32 = 1
    private var origin = FrameOrigin()

    /// The 80 ms frame index of the first row of the most recent block.
    public var tapFrameOrigin: Int { origin.blockStart }

    private var rowHistory: [[[Float]]] = []
    private static let zeroRow = [Float](repeating: 0, count: MelFeatures.nMels)

    /// - Parameters:
    ///   - artifactURL: the `.mlpackage` (or compiled `.mlmodelc`).
    ///   - stepURL: the student/teacher step beside it. Shared with the cut tier.
    ///   - promptID: explicit override; normally nil so the value is resolved from the
    ///     artifact's declared metadata. The English ASR manager never supplies one, so
    ///     this path must be told where its value comes from rather than baking 101.
    public init(artifactURL: URL, stepURL: URL, promptID: Int? = nil) throws {
        let model = try Self.load(artifactURL)
        let d = model.modelDescription

        func input(_ name: String) throws -> [Int] {
            guard let c = d.inputDescriptionsByName[name]?.multiArrayConstraint else {
                throw LoadError.malformedArtifact("no \(name) input")
            }
            return c.shape.map { $0.intValue }
        }
        func output(_ name: String) throws -> [Int] {
            guard let c = d.outputDescriptionsByName[name]?.multiArrayConstraint else {
                throw LoadError.malformedArtifact("no \(name) output")
            }
            return c.shape.map { $0.intValue }
        }

        let mel = try input("mel")
        let ch = try input("cache_channel")
        let ct = try input("cache_time")
        let tap = try output("tap_l4")
        guard mel.count == 3, ch.count == 4, ct.count == 4, tap.count == 3 else {
            throw LoadError.malformedArtifact("unexpected input/output ranks")
        }
        guard mel[1] == MelFeatures.nMels else {
            throw LoadError.malformedArtifact("\(mel[1]) mel channels, expected \(MelFeatures.nMels)")
        }
        guard ch[0] == mel[0], ct[0] == mel[0], tap[0] == mel[0],
              ch[1] == ct[1], ch[3] == ct[2], tap[1] == ch[3],
              ct[3] == 8, ch[2] > 0, tap[2] > 0 else {
            throw LoadError.malformedArtifact("inconsistent batch/layer/width dims")
        }
        let shape = Shape(batch: mel[0], layers: ch[1], cacheDepth: ch[2],
                          totalMelFrames: mel[2],
                          newMelFrames: TurnRuntime.hopSamples / MelFeatures.hopLength,
                          tapRowsPerChunk: tap[2], hidden: ch[3])
        guard shape.totalMelFrames > shape.newMelFrames,
              shape.tapRowsPerChunk * MelFeatures.hopLength * 8 == TurnRuntime.hopSamples else {
            // tap rows are 80 ms frames; one hop must release exactly those frames
            throw LoadError.cadenceMismatch(totalMel: mel[2], tapRows: tap[2])
        }
        self.shape = shape

        // The sidecar is the export's own metadata. Its cache depth must describe the
        // graph beside it (the 70-vs-42 defect); its prompt_id is the declared source.
        let declared = Self.sidecar(for: artifactURL)
        if let declaredDepth = declared.cacheDepth, declaredDepth != shape.cacheDepth {
            throw LoadError.cacheDepthMismatch(artifact: shape.cacheDepth, declared: declaredDepth)
        }
        if let promptID {
            self.promptID = promptID
        } else if let declaredID = declared.promptID ?? Self.metadataPromptID(d) {
            self.promptID = declaredID
        } else {
            throw LoadError.noPromptID
        }
        self.model = model
        self.step = try CoreMLStep(stepURL: stepURL)

        // MLMultiArray memory is not zeroed for us; the caches must start at the
        // export's all-zero state (the manager seeds only `cache_len`).
        self.cacheChannel = Self.filled(shape.cacheChannelShape, .float32, with: 0)
        self.cacheTime = Self.filled(shape.cacheTimeShape, .float32, with: 0)
        self.cacheLen = Self.filled([shape.batch], .int32, with: Self.initialCacheLength)
        self.melStreams = (0..<shape.batch).map { _ in StreamingMel() }
        self.rowHistory = Array(repeating: [], count: shape.batch)
    }

    // MARK: - TurnModel

    /// The heads' context starts over; the ears' audio streams do not. A cold encoder
    /// cache costs ~4 cosine points for ~6 chunks (#132), so resetting it per utterance
    /// is exactly what this tier must not do.
    public func reset() {
        step.reset()
    }

    /// A real stream restart (new call, or a power-saving stop): caches, mel history
    /// and the origin rebase together.
    public func restartStreams() {
        cacheChannel = Self.filled(shape.cacheChannelShape, .float32, with: 0)
        cacheTime = Self.filled(shape.cacheTimeShape, .float32, with: 0)
        cacheLen = Self.filled([shape.batch], .int32, with: initialCacheLengthValue)
        for m in melStreams { m.reset() }
        rowHistory = Array(repeating: [], count: shape.batch)
        origin.restartStream()
    }

    /// One 320 ms hop of one ear (the mic slot), streaming. ``TurnRuntime`` uses
    /// ``encodePair(mic:playback:)`` instead; this exists for the seam and tests. The
    /// other slot(s) get silence, as an idle ear does in the runtime.
    public func encode(_ window: [Float]) -> [[Float]] {
        origin.feed(rowsPerChunk: shape.tapRowsPerChunk)
        var windows: [Int: [[Float]]] = [:]
        if let rows = melWindow(after: window, slot: 0) { windows[0] = rows }
        // A fixed-shape B=2 graph has no way to skip a slot, so the other ear gets the
        // same treatment the runtime gives an idle one: silence, caches kept warm.
        for slot in 1..<shape.batch {
            if let rows = melWindow(after: Self.silence, slot: slot) { windows[slot] = rows }
        }
        guard windows.count == shape.batch else { return [] }
        return predict(rowsBySlot: windows)[0] ?? []
    }

    public func encodePair(mic: [Float], playback: [Float])
        -> (mic: [[Float]], playback: [[Float]]) {
        // Both streams advance every hop, silence included: a skipped hop is a cold
        // cache for that ear. The window may still be filling, which only means no call.
        origin.feed(rowsPerChunk: shape.tapRowsPerChunk)
        let micRows = melWindow(after: mic, slot: 0)
        let playRows = shape.batch > 1 ? melWindow(after: playback, slot: 1) : nil
        guard let micRows else { return ([], []) }
        guard shape.batch > 1 else { return (predict(rowsBySlot: [0: micRows])[0] ?? [], []) }
        guard let playRows else { return ([], []) }
        let rows = predict(rowsBySlot: [0: micRows, 1: playRows])
        return (rows[0] ?? [], rows[1] ?? [])
    }

    public func step(hu: [Float], ha: [Float], actDb: Double, prevState: Int) -> [Float] {
        step.step(hu: hu, ha: ha, actDb: actDb, prevState: prevState)
    }

    // MARK: - streaming

    /// Append one hop to a slot and return its last `totalMelFrames` mel rows once the
    /// window is full. Row `g` exists once its centered 512-sample STFT window is in, so
    /// the artifact's 41 rows need 426 ms of audio — more than one 320 ms hop. Since the
    /// runtime calls on hop boundaries, the first call lands on the second one and each
    /// hop then releases `tapRowsPerChunk` rows. shortcut: startup drops the first
    /// ~310 ms of audio (the offline pass has real rows 0..40 at 426 ms); upgrade if
    /// first-decision latency ever matters.
    private func melWindow(after hop: [Float], slot: Int) -> [[Float]]? {
        let stream = melStreams[slot]
        rowHistory[slot].append(contentsOf: stream.append(Self.hop(hop)))
        if rowHistory[slot].count > shape.totalMelFrames {
            rowHistory[slot].removeFirst(rowHistory[slot].count - shape.totalMelFrames)
        }
        guard stream.rowCount >= shape.totalMelFrames else { return nil }
        return rowHistory[slot]
    }

    /// One batched prediction. Every slot must be present: a fixed-shape B=2 graph cannot
    /// skip one, and a half-fed call would leave the two caches at different lengths.
    private func predict(rowsBySlot: [Int: [[Float]]]) -> [Int: [[Float]]] {
        let b = shape.batch, t = shape.totalMelFrames, h = shape.hidden
        guard rowsBySlot.count == shape.batch, let mel = try? MLMultiArray(
            shape: [b, MelFeatures.nMels, t].map { NSNumber(value: $0) }, dataType: .float32)
        else { return [:] }
        let melPtr = mel.dataPointer.bindMemory(to: Float.self, capacity: b * MelFeatures.nMels * t)
        for slot in 0..<b {
            let rows = rowsBySlot[slot] ?? []
            for r in 0..<t {
                let row = r < rows.count ? rows[r] : Self.zeroRow
                for m in 0..<MelFeatures.nMels {
                    melPtr[(slot * MelFeatures.nMels + m) * t + r] = row[m]
                }
            }
        }
        let provider = try? MLDictionaryFeatureProvider(dictionary: [
            "mel": mel,
            "mel_length": Self.filled([b], .int32, with: Int32(t)),
            "cache_channel": cacheChannel,
            "cache_time": cacheTime,
            "cache_len": cacheLen,
            "prompt_id": Self.filled([b], .int32, with: Int32(promptID)),
        ])
        guard let provider, let out = try? model.prediction(from: provider),
              let tap = out.featureValue(for: "tap_l4")?.multiArrayValue,
              let chOut = out.featureValue(for: "cache_channel_out")?.multiArrayValue,
              let ctOut = out.featureValue(for: "cache_time_out")?.multiArrayValue,
              let lenOut = out.featureValue(for: "cache_len_out")?.multiArrayValue else {
            return [:]
        }
        let k = shape.tapRowsPerChunk
        let tapPtr = tap.dataPointer.bindMemory(to: Float.self, capacity: b * h * k)
        var result: [Int: [[Float]]] = [:]
        for slot in rowsBySlot.keys.sorted() where slot < b {
            var rows: [[Float]] = []
            rows.reserveCapacity(k)
            for r in 0..<k {
                var row = [Float](repeating: 0, count: h)
                for d in 0..<h {
                    row[d] = tapPtr[(slot * h + d) * k + r]
                }
                rows.append(row)
            }
            result[slot] = rows
        }
        // Every slot advanced (all are fed each call), so the outputs are the caches.
        cacheChannel = chOut
        cacheTime = ctOut
        let lenPtr = cacheLen.dataPointer.bindMemory(to: Int32.self, capacity: b)
        let lenOutPtr = lenOut.dataPointer.bindMemory(to: Int32.self, capacity: b)
        for slot in rowsBySlot.keys where slot < b {
            lenPtr[slot] = lenOutPtr[slot]
        }
        if rowsBySlot[0] != nil { origin.release(rowsPerChunk: k) }
        return result
    }

    private var initialCacheLengthValue: Int32 { Self.initialCacheLength }

    /// One hop exactly: short input is padded with silence (an idle ear still
    /// advances), long input keeps its newest 320 ms. Both ears go through this, so
    /// their caches cannot desynchronise by a caller's buffer length.
    private static func hop(_ x: [Float]) -> [Float] {
        if x.count == TurnRuntime.hopSamples { return x }
        var y = [Float](repeating: 0, count: TurnRuntime.hopSamples)
        let n = min(x.count, y.count)
        y.replaceSubrange(0..<n, with: x[(x.count - n)...])
        return y
    }

    // MARK: - artifact helpers

    private static func load(_ url: URL) throws -> MLModel {
        let compiled = (try? MLModel.compileModel(at: url)) ?? url
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        do {
            return try MLModel(contentsOf: compiled, configuration: config)
        } catch {
            throw LoadError.malformedArtifact("cannot load \(url.lastPathComponent): \(error)")
        }
    }

    private struct Sidecar {
        var promptID: Int?
        var cacheDepth: Int?
    }

    /// `metadata.json` beside the artifact (the export writes one per artifact).
    private static func sidecar(for artifactURL: URL) -> Sidecar {
        let url = artifactURL.deletingLastPathComponent().appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Sidecar()
        }
        let shape = root["cache_channel_shape"] as? [Any]
        return Sidecar(promptID: root["prompt_id"] as? Int,
                       cacheDepth: shape.flatMap { $0.count == 4 ? ($0[2] as? Int) : nil })
    }

    private static func metadataPromptID(_ description: MLModelDescription) -> Int? {
        let meta = description.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String]
        return meta?["prompt_id"].flatMap { Int($0) }
    }

    private static func filled(_ dims: [Int], _ type: MLMultiArrayDataType,
                               with value: Int32) -> MLMultiArray {
        let a = try! MLMultiArray(shape: dims.map { NSNumber(value: $0) }, dataType: type)
        if type == .int32 {
            let p = a.dataPointer.bindMemory(to: Int32.self, capacity: a.count)
            for i in 0..<a.count { p[i] = value }
        } else {
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
            for i in 0..<a.count { p[i] = Float(value) }
        }
        return a
    }

    /// The idle ear's hop: the graph cannot skip a slot, and a skipped hop is a cold
    /// cache for that ear (`docs/voice-tyger-ondevice.md` § "The playback ear").
    private static let silence = [Float](repeating: 0, count: TurnRuntime.hopSamples)
}

/// Frame origins for a streaming tap (`tapFrameOrigin`), derived from the audio this
/// consumer fed instead of from the encoder's row counter.
///
/// The fork's origin counts released rows and survives `reset()`; a restarted stream
/// re-emits its context row, so it drifts +1 frame per restart (#174: 0 → 1400 → 2520
/// on 7-row chunks), and audio skipped while not feeding is missing from it entirely.
/// The audio clock cannot drift: a restart re-encodes audio that was already counted.
public struct FrameOrigin: Equatable {
    /// 80 ms audio frames fed to the stream; never rewound.
    public private(set) var audioFrames = 0
    /// The frame index of the first row released by the most recent chunk.
    public private(set) var blockStart = 0

    public init() {}

    /// Audio for one hop arrived. The clock counts what was fed, not what was
    /// released: a restart consumes its pre-context from this clock, not from a
    /// row counter.
    public mutating func feed(rowsPerChunk: Int) {
        audioFrames += rowsPerChunk
    }

    /// A chunk released `rowsPerChunk` tap rows; their first row is the last
    /// `rowsPerChunk` audio frames that were fed.
    public mutating func release(rowsPerChunk: Int) {
        blockStart = audioFrames - rowsPerChunk
    }

    /// A heads reset (rules reset point / mode switch) must not touch the stream.
    public mutating func resetHeads() {}

    /// A stream restart keeps the audio clock; the next block rebases onto it.
    public mutating func restartStream() {
        blockStart = audioFrames
    }

    public func frame(ofRow row: Int) -> Int { blockStart + row }
}

/// The turn prefix's switch and its place in the model store.
public enum TurnPrefix {
    /// Default on since the 2026-11-05 ruling (#132, #185): `IDFON_TURN_PREFIX=0`
    /// (or `no`/`off`/`false`) is the kill switch back to the cut, no rebuild needed.
    /// Unset is on; a set but unrecognized value keeps the cut (fail-open).
    public static let environmentKey = "IDFON_TURN_PREFIX"

    public static func isEnabled(environment: [String: String]) -> Bool {
        guard let raw = environment[environmentKey]?.lowercased() else { return true }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    /// The prefix artifact inside the model store: `<root>/prefix/`, holding exactly
    /// one package, beside — not replacing — the cut tier's files at the root. More
    /// than one (or none) is ambiguous: nil, and the caller keeps today's cut.
    public static func artifact(in root: URL) -> URL? {
        let dir = root.appendingPathComponent("prefix")
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let packages = items.filter { $0.pathExtension == "mlpackage" || $0.pathExtension == "mlmodelc" }
        return packages.count == 1 ? packages[0] : nil
    }
}
