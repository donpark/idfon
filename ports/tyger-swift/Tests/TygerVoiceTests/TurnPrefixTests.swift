import AVFoundation
import XCTest
@testable import TygerVoice

/// The 320 ms turn-prefix tier (`docs/voice-tyger-ondevice.md` § "The 320 refit and a
/// turn-purpose prefix", § "Batched ears and the silent-ear cache on the 320 ms
/// prefix"): layers 0-3 of the shipping encoder, batched two ears in one cache-aware
/// call, 4 tap rows per 320 ms hop. Nothing here is enabled unless the caller asks
/// for it; the default tier is the windowed cut, pinned by `TurnRuntimeGoldenTests`.
///
/// The artifacts and the runtime fixture are gitignored, so the model tests skip
/// without them. To reproduce:
///
///   ports/tyger-student/.venv/bin/python ports/tyger-student/export_asr_tap.py \
///       --export --prefix-only --depth 4 --batch 2 --chunk-ms 320 --pass shipping \
///       --precision fp16 --int8 --out bench-results/asr-prefix-320
///   # and the same with --batch 1, plus the 24-layer 320 export in asr-tap-320
final class TurnPrefixTests: XCTestCase {
    private var repoRoot: URL {
        // .../ports/tyger-swift/Tests/TygerVoiceTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var bench: URL {
        ProcessInfo.processInfo.environment["IDFON_BENCH"].map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("bench-results")
    }

    /// The prefix export pair: one 2-slot artifact (the runtime's shape) and its
    /// batch-1 sibling (the un-batched control).
    private var batchedPrefix: URL {
        bench.appendingPathComponent("asr-prefix-320/encoder_tap_42-13_320ms_fp16_int8w_l4b2.mlpackage")
    }
    private var singlePrefix: URL {
        bench.appendingPathComponent("asr-prefix-320/encoder_tap_42-13_320ms_fp16_int8w_l4b1.mlpackage")
    }
    /// The 24-layer 320 ms encoder the ASR tier would run — only its tap is compared.
    private var fullEncoder: URL {
        bench.appendingPathComponent("asr-tap-320/encoder_tap_42-13_320ms_fp16_int8w.mlpackage")
    }
    private var step: URL { bench.appendingPathComponent("coreml/StudentStep.mlpackage") }

    private func require(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("artifact not exported: \(url.lastPathComponent)")
        }
    }

    // MARK: - fixtures

    private struct Fixture {
        let mic: [Float]
        let playback: [Float]
    }

    /// The mic ear is the runtime fixture when this checkout has it (real speech), a
    /// deterministic pseudo-speech signal otherwise, so the model tests still run from
    /// a fresh worktree. The playback ear is always pseudo-speech: the runtime dump's
    /// two channels carry the *same* audio for the first seconds, and two equal ears
    /// would hide a slot mix-up (the thing these tests exist to catch).
    private func fixture() -> Fixture {
        let dir = repoRoot.appendingPathComponent("ports/tyger-swift/Tests/TygerVoiceTests/runtime")
        let mic = (try? readWav(dir.appendingPathComponent("ch0.wav"))).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.pseudoSpeech(seed: 1)
        return Fixture(mic: mic, playback: Self.pseudoSpeech(seed: 2))
    }

    /// 3 s of deterministic voiced-ish audio: a moving-pitch buzz with a gate (speech
    /// and pauses) and a seeded noise floor. Fixed by construction, no fixture file.
    static func pseudoSpeech(seed: UInt64, seconds: Double = 3) -> [Float] {
        var state = seed &* 0x9E3779B97F4A7C15 &+ 1
        func rnd() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float((state >> 40) & 0xFFFF) / 32768.0 - 1.0
        }
        let n = Int(seconds * Double(TurnRuntime.sampleRate))
        var out = [Float](repeating: 0, count: n)
        var phase: Float = 0
        for i in 0..<n {
            let t = Float(i) / Float(TurnRuntime.sampleRate)
            let f0: Float = 140 + 25 * sinf(2 * .pi * 0.7 * t)
            phase += 2 * .pi * f0 / Float(TurnRuntime.sampleRate)
            let gate: Float = sinf(2 * .pi * 0.45 * t) > -0.2 ? 1 : 0
            out[i] = 0.2 * gate * (sinf(phase) + 0.4 * sinf(2 * phase + 0.5) + 0.02 * rnd())
        }
        return out
    }

    private func readWav(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let n = AVAudioFrameCount(f.length)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try f.read(into: buf)
        let ch = buf.floatChannelData![0]
        return (0..<Int(n)).map { ch[$0] }
    }

    private func hops(_ audio: [Float], _ count: Int) -> [[Float]] {
        (0..<count).map { h in
            let s = h * TurnRuntime.hopSamples
            guard s + TurnRuntime.hopSamples <= audio.count else {
                return [Float](repeating: 0, count: TurnRuntime.hopSamples)
            }
            return Array(audio[s..<s + TurnRuntime.hopSamples])
        }
    }

    // MARK: - the artifact's framing is the source of truth

    func testShapeComesFromTheArtifactNotTheShippingMetadata() throws {
        try require(batchedPrefix)
        try require(step)
        let m = try TurnPrefixModel(artifactURL: batchedPrefix, stepURL: step)
        let s = m.shape
        // The shipping 42/13 export's own geometry. The base (56/0) bundle's
        // metadata.json says 70 for the same field — the mismatch that once shipped
        // beside a 42-deep artifact. Read from the model description, asserted at load.
        XCTAssertEqual(s.cacheDepth, 42)
        XCTAssertEqual(s.layers, 4)
        XCTAssertEqual(s.totalMelFrames, 41)
        XCTAssertEqual(s.tapRowsPerChunk, 4)
        XCTAssertEqual(s.newMelFrames, TurnRuntime.hopSamples / MelFeatures.hopLength)
        XCTAssertEqual(s.preEncodeMelFrames, 9, "the artifact's pre-encode context")
        XCTAssertEqual(s.batch, 2)
        XCTAssertEqual(m.artifactCacheDepth, s.cacheDepth)
        XCTAssertEqual(m.promptID, 101, "declared by the export's metadata.json")
    }

    /// The loader refuses an artifact whose sidecar disagrees with the graph, and it
    /// refuses to invent a prompt id. Both are what "fail open to the cut" keys on.
    func testLoaderRejectsMismatchedMetadataAndUndeclaredPrompt() throws {
        try require(batchedPrefix)
        try require(step)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let link = tmp.appendingPathComponent(batchedPrefix.lastPathComponent)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: batchedPrefix)
        let meta = tmp.appendingPathComponent("metadata.json")

        // (a) the 70-vs-42 shape mismatch is refused, not silently used.
        try #"{"prompt_id": 101, "cache_channel_shape": [2, 4, 70, 1024]}"#
            .write(to: meta, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TurnPrefixModel(artifactURL: link, stepURL: step)) { error in
            guard let e = error as? TurnPrefixModel.LoadError,
                  case .cacheDepthMismatch(42, 70) = e else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // (b) no declared prompt_id anywhere: refuse. The English manager's 101 is a
        // const baked into *its* export; this path must be told where its value comes
        // from rather than defaulting to the same number.
        try #"{"cache_channel_shape": [2, 4, 42, 1024]}"#
            .write(to: meta, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TurnPrefixModel(artifactURL: link, stepURL: step)) { error in
            guard let e = error as? TurnPrefixModel.LoadError, case .noPromptID = e else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // (c) declared -> used; an explicit override wins over the sidecar.
        try #"{"prompt_id": 101, "cache_channel_shape": [2, 4, 42, 1024]}"#
            .write(to: meta, atomically: true, encoding: .utf8)
        XCTAssertEqual(try TurnPrefixModel(artifactURL: link, stepURL: step).promptID, 101)
        XCTAssertEqual(try TurnPrefixModel(artifactURL: link, stepURL: step, promptID: 7).promptID, 7)
    }

    /// Default-on since the 2026-11-05 ruling (#132): real use is the test, and the
    /// env var is the kill switch that returns to the cut without a rebuild.
    func testFlagIsOnUnlessKilled() {
        XCTAssertTrue(TurnPrefix.isEnabled(environment: [:]))
        XCTAssertFalse(TurnPrefix.isEnabled(environment: ["IDFON_TURN_PREFIX": "0"]))
        XCTAssertFalse(TurnPrefix.isEnabled(environment: ["IDFON_TURN_PREFIX": "no"]))
        XCTAssertFalse(TurnPrefix.isEnabled(environment: ["IDFON_TURN_PREFIX": "off"]))
        XCTAssertTrue(TurnPrefix.isEnabled(environment: ["IDFON_TURN_PREFIX": "1"]))
        XCTAssertTrue(TurnPrefix.isEnabled(environment: ["IDFON_TURN_PREFIX": "true"]))
    }

    /// `<root>/prefix/` with exactly one package; the cut tier's files at the root are
    /// untouched, and an ambiguous directory fails open (nil) instead of guessing.
    func testPrefixArtifactLivesBesideTheCutWithoutBreakingIt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let prefix = tmp.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("StudentStep.mlpackage"), withIntermediateDirectories: true)
        XCTAssertNil(TurnPrefix.artifact(in: tmp), "no prefix package -> fall back to the cut")

        let pkg = prefix.appendingPathComponent("encoder_l4b2.mlpackage")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        XCTAssertEqual(TurnPrefix.artifact(in: tmp)?.lastPathComponent, "encoder_l4b2.mlpackage")

        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("encoder_l4b1.mlpackage"), withIntermediateDirectories: true)
        XCTAssertNil(TurnPrefix.artifact(in: tmp), "two packages are ambiguous -> fall back")
    }

    // MARK: - batching is exact

    /// One 2-slot call per hop == two un-batched calls, per ear, per row. The export
    /// measured cos 1.0 / max|d| 0.0; that is the wiring gate, so this asserts exact
    /// equality, not a tolerance.
    func testBatchedTwoEarEqualsTwoSingleEarCalls() throws {
        try require(batchedPrefix)
        try require(singlePrefix)
        try require(step)
        let fx = fixture()
        let n = 12
        let mic = hops(fx.mic, n), play = hops(fx.playback, n)

        let pair = try TurnPrefixModel(artifactURL: batchedPrefix, stepURL: step)
        let a = try TurnPrefixModel(artifactURL: singlePrefix, stepURL: step)
        let b = try TurnPrefixModel(artifactURL: singlePrefix, stepURL: step)
        var compared = 0
        for h in 0..<n {
            let both = pair.encodePair(mic: mic[h], playback: play[h])
            let one = a.encode(mic[h]), two = b.encode(play[h])
            XCTAssertEqual(both.mic.count, one.count, "rows per hop (mic)")
            XCTAssertEqual(both.playback.count, two.count, "rows per hop (playback)")
            if h > 0 { XCTAssertFalse(both.mic.isEmpty, "a hop after the first must release rows") }
            for (x, y) in zip(both.mic, one) {
                XCTAssertEqual(x, y, "mic ear deviates from the un-batched call")
                compared += x.count
            }
            for (x, y) in zip(both.playback, two) {
                XCTAssertEqual(x, y, "playback ear deviates from the un-batched call")
                compared += x.count
            }
        }
        XCTAssertGreaterThan(compared, 0, "no rows were compared")
        // Independent caches: two different signals through two slots must not yield
        // the same rows (a shared slot would).
        let both = pair.encodePair(mic: mic[n - 1], playback: play[n - 1])
        XCTAssertNotEqual(both.mic.last, both.playback.last, "the two slots share a cache")
    }

    // MARK: - the prefix is the full encoder's tap

    /// `hidden_states[4]` is layers 0-3's output, so a 4-layer export emits the full
    /// model's tap rows bit-for-bit (export parity `max|d| 0.0`). Compared through the
    /// same streaming mel and cache threading — the app path, not the artifact file.
    func testPrefixTapEqualsFullModelTap() throws {
        try require(batchedPrefix)
        try require(fullEncoder)
        try require(step)
        let fx = fixture()
        let n = 12
        let mic = hops(fx.mic, n)

        // The export's documented parity pair is batch 1 vs the 24-layer graph (the
        // batching equality above covers the 2-slot form).
        let prefix = try TurnPrefixModel(artifactURL: singlePrefix, stepURL: step)
        // A full ASR-shaped export carries no turn-path prompt_id in its metadata;
        // this test compares the graphs, so the value is explicit.
        let full = try TurnPrefixModel(artifactURL: fullEncoder, stepURL: step, promptID: 101)
        XCTAssertEqual(full.shape.cacheDepth, 42)
        XCTAssertEqual(full.shape.layers, 24, "the ASR-shaped graph keeps all 24 layers")
        var worst: Float = 0
        var rows = 0
        for h in 0..<n {
            let p = prefix.encode(mic[h])
            let f = full.encode(mic[h])
            XCTAssertEqual(p.count, f.count)
            for (x, y) in zip(p, f) {
                XCTAssertEqual(x.count, y.count)
                for (u, v) in zip(x, y) {
                    worst = max(worst, abs(u - v))
                    rows += 1
                }
            }
        }
        XCTAssertGreaterThan(rows, 0)
        // The export's measured parity: the prefix *is* layers 0-3 of the same graph.
        XCTAssertEqual(worst, 0, "the prefix tap is not bit-identical to the full model's")
    }

    // MARK: - frame origin across a reset

    /// The measured wiring bug (#174): the fork's `tapFrameOrigin` survives `reset()`
    /// and a restarted stream re-emits its context row, so an origin derived from the
    /// row counter drifts +1 frame per restart. The audio clock does not.
    func testFrameOriginRebaseAcrossRestart() {
        var origin = FrameOrigin()
        origin.feed(rowsPerChunk: 4)
        origin.release(rowsPerChunk: 4)
        XCTAssertEqual(origin.frame(ofRow: 0), 0)
        XCTAssertEqual(origin.frame(ofRow: 3), 3)
        origin.feed(rowsPerChunk: 4)
        origin.release(rowsPerChunk: 4)
        XCTAssertEqual(origin.frame(ofRow: 0), 4)

        // A heads reset (rules reset point / mode switch) must not touch the stream.
        origin.resetHeads()
        origin.feed(rowsPerChunk: 4)
        origin.release(rowsPerChunk: 4)
        XCTAssertEqual(origin.frame(ofRow: 0), 8, "a head reset must not rewind the stream")

        // A real restart discards the caches; the next block rebases onto the audio
        // clock instead of restarting a row counter (the +1-per-restart drift).
        origin.restartStream()
        XCTAssertEqual(origin.frame(ofRow: 0), 12, "a restart must not rewind the audio clock")
        origin.feed(rowsPerChunk: 4)
        origin.release(rowsPerChunk: 4)
        XCTAssertEqual(origin.frame(ofRow: 0), 12)
        XCTAssertEqual(origin.frame(ofRow: 3), 15)
    }

    /// Same property through the model: `reset()` (heads) keeps the audio stream;
    /// `restartStreams()` rebases and does not drift a frame.
    func testModelOriginAcrossHeadsResetAndStreamRestart() throws {
        try require(batchedPrefix)
        try require(step)
        let fx = fixture()
        let model = try TurnPrefixModel(artifactURL: batchedPrefix, stepURL: step)
        let mic = hops(fx.mic, 10), play = hops(fx.playback, 10)
        var origins: [Int] = []
        for h in 0..<10 {
            _ = model.encodePair(mic: mic[h], playback: play[h])
            origins.append(model.tapFrameOrigin)
            if h == 3 { model.reset() }   // the rules' reset point: caches must survive
        }
        let deltas = zip(origins.dropFirst(), origins).map { $0 - $1 }
        XCTAssertTrue(deltas.allSatisfy { $0 == 0 || $0 == 4 }, "origin steps: \(deltas)")
        XCTAssertEqual(origins, [0, 4, 8, 12, 16, 20, 24, 28, 32, 36])

        let before = model.tapFrameOrigin
        model.restartStreams()
        XCTAssertEqual(model.tapFrameOrigin, before + 4, "the restart rebases onto the audio clock")
        var last = model.tapFrameOrigin
        for h in [9, 8, 7] {
            _ = model.encodePair(mic: mic[h], playback: play[h])
            let now = model.tapFrameOrigin
            XCTAssertGreaterThanOrEqual(now, last, "the origin must never rewind")
            // The first post-restart hop is the new stream's pre-context (8 frames of
            // audio, no released block); after that a hop is exactly 4 frames, never 5.
            XCTAssertEqual(now - last, h == 9 ? 0 : 4)
            last = now
        }
    }

    // MARK: - the streaming mel is the windowed mel

    /// The prefix consumes 41 consecutive mel rows per 320 ms hop. A row exists once
    /// its whole 512-sample STFT window is in, so the stream must produce exactly the
    /// rows `MelFeatures.process` produces for the whole signal — the grid every
    /// measured number uses. No model needed.
    func testStreamingMelReproducesTheWholeSignalMel() {
        let audio = Self.pseudoSpeech(seed: 7, seconds: 2.5)
        let (whole, _) = MelFeatures.process(audio)

        // One shot: every row whose 512-sample window is complete.
        let oneShot = StreamingMel()
        let rowsOneShot = oneShot.append(audio)
        XCTAssertEqual(rowsOneShot.count,
                       (audio.count - MelFeatures.nFFT / 2) / MelFeatures.hopLength + 1)
        // The whole-signal pass's last row is completed by its right padding (it is not
        // audio) and one row past it is the extractor's masked artefact — a stream emits
        // neither until the audio for them arrives.
        for (g, row) in rowsOneShot.enumerated() {
            XCTAssertEqual(row, whole[g], "mel row \(g) deviates from the windowed extractor")
        }

        // Hop-fed must produce the same rows, in the same order (the app's shape).
        let hopFed = StreamingMel()
        var rowsHop: [[Float]] = []
        for s in stride(from: 0, to: audio.count - TurnRuntime.hopSamples + 1,
                        by: TurnRuntime.hopSamples) {
            rowsHop.append(contentsOf: hopFed.append(Array(audio[s..<s + TurnRuntime.hopSamples])))
        }
        XCTAssertEqual(rowsHop, Array(rowsOneShot.prefix(rowsHop.count)))
    }

    /// The runtime's flag-off path stays the windowed cut: two `encode(window)` calls
    /// per hop. (The numeric default is pinned by `TurnRuntimeGoldenTests`.)
    func testFlagOffRuntimeStillUsesTheWindowedCut() throws {
        let cut = WindowedCounterModel()
        let rt = TurnRuntime(model: cut)
        for _ in 0..<3 {
            _ = rt.feed(userHop: [Float](repeating: 0.1, count: TurnRuntime.hopSamples),
                        agentHop: [Float](repeating: 0.2, count: TurnRuntime.hopSamples),
                        prevState: { _ in 0 })
        }
        XCTAssertEqual(cut.encodeCalls, 6, "the flag-off path encodes each ear separately")
    }
}

/// Records how the runtime fed a model (the flag-off wiring).
private final class WindowedCounterModel: TurnModel {
    var encodeCalls = 0
    func reset() {}
    func encode(_ window: [Float]) -> [[Float]] {
        encodeCalls += 1
        let frames = window.count / (MelFeatures.hopLength * 8)
        return Array(repeating: [Float](repeating: 0.5, count: 1024), count: frames)
    }
    func step(hu: [Float], ha: [Float], actDb: Double, prevState: Int) -> [Float] {
        [Float](repeating: 0, count: 8)
    }
}
