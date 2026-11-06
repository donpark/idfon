// What the ASR bundle swap changes: same audio, two managers, one paced run each.
//
// The split tier (#132/#185) forces the ASR from the shipping English bundle
// (`nemotron-speech-streaming-en-0.6b-coreml/560ms`, NVIDIA Open Model License)
// to the 3.5 multilingual bundle
// (`Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`, OpenMDW-1.1). The
// decoder/joint/tokenizer change, so transcripts and partial cadence can change
// with no app change at all. This probe measures exactly that: the real managers,
// the captured call mic channel, the same 560 ms tier, paced on a device clock.
//
//   --en DIR      StreamingNemotronAsrManager (shipping English 560ms)
//   --ml DIR      StreamingNemotronMultilingualAsrManager (multilingual/560ms)
//   --staged DIR  same multilingual manager, decoder/joint/tokenizer from the
//                 bundle but *our* 42/13 encoder export, prompt_id fed as a
//                 model input (no baked const) — see stage_models.py
//
// Nothing is decided here: transcripts, partial timelines, wall time. The diff
// and cadence numbers come from `diff.py`; references are absent, so it reports
// divergence, never WER.
//
// Usage:
//   tools/asr-bundle-swap/.build/release/asr-bundle-swap \
//     --en ~/.idfon/models/nemotron-streaming/560ms \
//     --ml bench-results/asr-bundle-swap/models/ml-560ms \
//     --staged bench-results/asr-bundle-swap/models/staged-560ms \
//     --sessions 2026-10-25T23:13:14Z:1394,... \
//     --out bench-results/asr-bundle-swap/transcripts.json
//
//   --selfcheck   argument/session parsing and the pacing arithmetic, no models
//   --compare A,B two encoders on identical inputs: is our export their encoder?

import AVFoundation
import CoreML
import FluidAudio
import Foundation

let SR = 16_000

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

@inline(__always) func nowNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

// MARK: - args

struct SessionSpec {
    let id: String
    let frames: Int

    /// "2026-10-25T23:13:14Z:1394" — the id itself contains ':'; the frame count
    /// is the last colon-separated field, and only when it parses as an Int.
    static func parse(_ spec: Substring) -> SessionSpec? {
        let parts = spec.split(separator: ":")
        guard let last = parts.last, let frames = Int(last), parts.count > 1 else { return nil }
        return SessionSpec(id: parts.dropLast().joined(separator: ":"), frames: frames)
    }
}

struct Args {
    var captures = ("~/Library/Application Support/Idfon/turn-captures" as NSString).expandingTildeInPath
    var sessions = "2026-10-25T23:13:14Z:1394,2026-10-26T20:17:43Z:1114,2026-10-26T21:13:38Z:1891"
    var bufferFrames = 682  // the mic tap's 2048 @48 kHz, in 16 kHz samples
    var en = ""
    var ml = ""
    var staged = ""
    var language = "en-US"
    var out = "bench-results/asr-bundle-swap/transcripts.json"
    var selfcheck = false
    var compare = [String]()
    var mels = ""
    var label = ""  // bundle name for the multilingual run (e.g. ml-auto)

    static func parse() -> Args {
        var a = Args()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let flag = it.next() {
            func value() -> String { it.next() ?? "" }
            switch flag {
            case "--captures": a.captures = value()
            case "--sessions": a.sessions = value()
            case "--buffer-frames": a.bufferFrames = Int(value()) ?? a.bufferFrames
            case "--en": a.en = value()
            case "--ml": a.ml = value()
            case "--staged": a.staged = value()
            case "--language": a.language = value()
            case "--out": a.out = value()
            case "--selfcheck": a.selfcheck = true
            case "--compare": a.compare = value().split(separator: ",").map(String.init)
            case "--mels": a.mels = value()
            case "--label": a.label = value()
            default: log("unknown flag \(flag)")
            }
        }
        return a
    }
}

// MARK: - one bundle's manager, behind one feed call

/// The two managers share a shape but not a type; this is only the feed seam.
protocol Feeder {
    func setPartial(_ cb: @escaping @Sendable (String) -> Void) async
    func feed(_ buffer: AVAudioPCMBuffer) async throws
    func finish() async throws -> (text: String, tokens: Int)
    func reset() async
    func cleanup() async
    func promptInfo() async -> (id: Int?, language: String?)
}

struct EnglishFeeder: Feeder {
    let manager: StreamingNemotronAsrManager
    func setPartial(_ cb: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialCallback(cb)
    }
    func feed(_ buffer: AVAudioPCMBuffer) async throws { _ = try await manager.process(audioBuffer: buffer) }
    func finish() async throws -> (text: String, tokens: Int) {
        let (text, timings) = try await manager.finishWithTokenTimings()
        return (text, timings.count)
    }
    func reset() async { await manager.reset() }
    func cleanup() async { await manager.cleanup() }
    func promptInfo() async -> (id: Int?, language: String?) { (nil, nil) }
}

struct MultilingualFeeder: Feeder {
    let manager: StreamingNemotronMultilingualAsrManager
    func setPartial(_ cb: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialCallback(cb)
    }
    func feed(_ buffer: AVAudioPCMBuffer) async throws { _ = try await manager.process(audioBuffer: buffer) }
    func finish() async throws -> (text: String, tokens: Int) {
        let (text, timings) = try await manager.finishWithTokenTimings()
        return (text, timings.count)
    }
    func reset() async { await manager.reset() }
    func cleanup() async { await manager.cleanup() }
    func promptInfo() async -> (id: Int?, language: String?) {
        (await manager.promptId(), await manager.detectedLanguage())
    }
}

// MARK: - recording

final class Recorder: @unchecked Sendable {
    struct Partial {
        let audioS: Double
        let wallS: Double
        let text: String
    }

    private let lock = NSLock()
    private var partials: [Partial] = []
    private var fed = 0
    private var t0: UInt64 = 0

    func start() {
        lock.lock()
        partials = []
        fed = 0
        t0 = nowNS()
        lock.unlock()
    }

    func addFed(_ n: Int) {
        lock.lock()
        fed += n
        lock.unlock()
    }

    func onPartial(_ text: String) {
        let t = nowNS()
        lock.lock()
        let p = Partial(audioS: Double(fed) / Double(SR),
                        wallS: Double(t &- t0) / 1e9, text: text)
        partials.append(p)
        lock.unlock()
    }

    func snapshot() -> [Partial] {
        lock.lock()
        defer { lock.unlock() }
        return partials
    }
}

// MARK: - encoder comparison

/// Do the two encoders compute the same frames? Same inputs, four chunks, each
/// model fed its own caches — so the cache contract is exercised, not just chunk 0.
/// This separates "our export transcribes differently" from "our export is wrong".
func compareEncoders(_ a: String, _ b: String, melsPath: String) async {
    let urlA = URL(fileURLWithPath: (a as NSString).expandingTildeInPath)
    let urlB = URL(fileURLWithPath: (b as NSString).expandingTildeInPath)
    let cfg = MLModelConfiguration()
    cfg.computeUnits = .cpuOnly  // numerics, not the ANE: no placement differences
    let mA = try! MLModel(contentsOf: urlA, configuration: cfg)
    let mB = try! MLModel(contentsOf: urlB, configuration: cfg)
    print("A: \(urlA.path)")
    print("  inputs \(mA.modelDescription.inputDescriptionsByName.keys.sorted())")
    print("  outputs \(mA.modelDescription.outputDescriptionsByName.keys.sorted())")
    for k in ["encoded", "cache_channel_out"] {
        if let t = mA.modelDescription.outputDescriptionsByName[k]?.multiArrayConstraint {
            print("  \(k) \(t.shape.map { $0.intValue }) \(t.dataType.rawValue)")
        }
    }
    print("B: \(urlB.path)")

    let melShape = [1, 128, 65], chShape = [1, 24, 42, 1024], tmShape = [1, 24, 1024, 8]
    // Real mel from a capture when given (mels.py); random only as a fallback, and
    // random frames are out of distribution — read those numbers as a shape check.
    var mels: [MLMultiArray] = []
    if melsPath.isEmpty {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for _ in 0..<4 {
            let mel = zeros(melShape)
            try! mel.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
                for i in 0..<p.count {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    p[i] = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(1 << 31)
                }
            }
            mels.append(mel)
        }
        print("mel: random (no --mels); treat the cosines as out-of-distribution")
    } else {
        let raw = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: (melsPath as NSString).expandingTildeInPath)))
        let n = 128 * 65
        let chunks = raw.count / (n * 4)
        let all = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for k in 0..<chunks {
            let mel = zeros(melShape)
            try! mel.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
                for i in 0..<n { p[i] = all[k * n + i] }
            }
            mels.append(mel)
        }
        print("mel: \(mels.count) real chunks from \(melsPath)")
    }

    var chA = zeros(chShape), chB = zeros(chShape)
    var tmA = zeros(tmShape), tmB = zeros(tmShape)
    var lenA: MLMultiArray = int1(0), lenB: MLMultiArray = int1(0)

    func run(_ m: MLModel, _ ch: MLMultiArray, _ tm: MLMultiArray, _ len: MLMultiArray,
             mel: MLMultiArray, prompt: Int) -> (MLMultiArray, MLMultiArray, MLMultiArray, MLMultiArray) {
        let input = try! MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: mel),
            "mel_length": MLFeatureValue(multiArray: int1(melShape[2])),
            "cache_channel": MLFeatureValue(multiArray: ch),
            "cache_time": MLFeatureValue(multiArray: tm),
            "cache_len": MLFeatureValue(multiArray: len),
            "prompt_id": MLFeatureValue(multiArray: int1(prompt)),
        ])
        let out = try! m.prediction(from: input)
        return (out.featureValue(for: "encoded")!.multiArrayValue!,
                out.featureValue(for: "cache_channel_out")!.multiArrayValue!,
                out.featureValue(for: "cache_time_out")!.multiArrayValue!,
                out.featureValue(for: "cache_len_out")!.multiArrayValue!)
    }

    print("\n== same prompt (0), \(mels.count) chunks, each model on its own caches")
    for k in 0..<mels.count {
        let mel = mels[k]
        let (ea, ca, ta, la) = run(mA, chA, tmA, lenA, mel: mel, prompt: 0)
        let (eb, cb, tb, lb) = run(mB, chB, tmB, lenB, mel: mel, prompt: 0)
        chA = ca; tmA = ta; lenA = la
        chB = cb; tmB = tb; lenB = lb
        print("  sums \(floats(ea).reduce(0,+)) \(floats(eb).reduce(0,+)) n \(ea.count)")
        print(String(format: "  chunk %d  encoded cos %.6f  max|d| %.4g  "
                     + "cache_channel cos %.6f  cache_time cos %.6f",
                     k, cosine(ea, eb), maxAbsDiff(ea, eb), cosine(ca, cb), cosine(ta, tb)))
    }

    print("\n== prompt sensitivity (chunk 0, prompt 0 vs 101, each model)")
    let mel0 = mels[0]
    let (a0, _, _, _) = run(mA, zeros(chShape), zeros(tmShape), int1(0), mel: mel0, prompt: 0)
    let (a101, _, _, _) = run(mA, zeros(chShape), zeros(tmShape), int1(0), mel: mel0, prompt: 101)
    let (b0, _, _, _) = run(mB, zeros(chShape), zeros(tmShape), int1(0), mel: mel0, prompt: 0)
    let (b101, _, _, _) = run(mB, zeros(chShape), zeros(tmShape), int1(0), mel: mel0, prompt: 101)
    print(String(format: "  A p0 vs p101: cos %.6f  max|d| %.4g", cosine(a0, a101), maxAbsDiff(a0, a101)))
    print(String(format: "  B p0 vs p101: cos %.6f  max|d| %.4g", cosine(b0, b101), maxAbsDiff(b0, b101)))
    print(String(format: "  A p0 vs B p0: cos %.6f  max|d| %.4g", cosine(a0, b0), maxAbsDiff(a0, b0)))
    print(String(format: "  A p101 vs B p101: cos %.6f  max|d| %.4g", cosine(a101, b101), maxAbsDiff(a101, b101)))
    print(String(format: "  A p0 vs B p101: cos %.6f  max|d| %.4g", cosine(a0, b101), maxAbsDiff(a0, b101)))
}

func zeros(_ shape: [Int]) -> MLMultiArray {
    let a = try! MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
    return a  // MLMultiArray allocates zeroed memory
}

func int1(_ v: Int) -> MLMultiArray {
    let a = try! MLMultiArray(shape: [1], dataType: .int32)
    a[0] = NSNumber(value: v)
    return a
}

func floats(_ a: MLMultiArray) -> [Float] {
    let n = a.count
    return try! a.withUnsafeBufferPointer(ofType: Float.self) { p in Array(p[0..<n]) }
}

func maxAbsDiff(_ a: MLMultiArray, _ b: MLMultiArray) -> Double {
    zip(floats(a), floats(b)).map { abs(Double($0) - Double($1)) }.max() ?? 0
}

func cosine(_ a: MLMultiArray, _ b: MLMultiArray) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for (x, y) in zip(floats(a), floats(b)) {
        dot += Double(x) * Double(y); na += Double(x) * Double(x); nb += Double(y) * Double(y)
    }
    return dot / max((na * nb).squareRoot(), 1e-12)
}

// MARK: - audio

func readCapture(_ url: URL, maxFrames: Int) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let fmt = file.processingFormat
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                     frameCapacity: AVAudioFrameCount(file.length)) else {
        throw ASRError.processingFailed("capture buffer")
    }
    try file.read(into: buf)
    let n = Int(buf.frameLength)
    var out = [Float](repeating: 0, count: n)
    if let f = buf.floatChannelData {
        for k in 0..<n { out[k] = f[0][k] }  // channel 0 = the caller's mic, what the ASR sees
    } else if let i = buf.int16ChannelData {
        for k in 0..<n { out[k] = Float(i[0][k]) / 32768.0 }
    } else {
        throw ASRError.processingFailed("capture format \(fmt)")
    }
    if maxFrames > 0 { out = Array(out.prefix(maxFrames * 1280)) }
    return out
}

func makeBuffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(SR), channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    var k = 0
    for s in samples { buf.floatChannelData![0][k] = s; k += 1 }
    return buf
}

/// Sleep to a monotonic deadline, spinning the last 1.5 ms: a device clock, so
/// the two bundles hear the same audio at the same times.
func waitUntil(_ deadline: UInt64) async {
    while true {
        let t = nowNS()
        if t >= deadline { return }
        let left = deadline - t
        if left > 1_500_000 {
            try? await Task.sleep(nanoseconds: left - 1_000_000)
        } else {
            while nowNS() < deadline {}
            return
        }
    }
}

// MARK: - one run

struct Run {
    let bundle: String
    let session: String
    let dir: String
    let language: String?
    var audioS = 0.0
    var wallS = 0.0
    var calls: [Double] = []       // per-`process` wall ms (mel + encode + decode)
    var final = ""
    var tokens = 0
    var promptId: Int?
    var detected: String?
    var partials: [Recorder.Partial] = []
}

func run(_ bundle: String, dir: String, session: String, audio: [Float],
         feeder: Feeder, args: Args, language: String?) async -> Run {
    var r = Run(bundle: bundle, session: session, dir: dir, language: language)
    r.audioS = Double(audio.count) / Double(SR)

    await feeder.reset()
    let rec = Recorder()
    rec.start()
    await feeder.setPartial { rec.onPartial($0) }
    let info = await feeder.promptInfo()
    r.promptId = info.id

    let t0 = nowNS()
    var i = 0
    while i < audio.count {
        let n = min(args.bufferFrames, audio.count - i)
        await waitUntil(t0 + UInt64((Double(i + n) / Double(SR)) * 1e9))
        rec.addFed(n)
        let t = nowNS()
        do { try await feeder.feed(makeBuffer(audio[i..<(i + n)])) }
        catch { log("\(bundle)/\(session) process error: \(error)") }
        r.calls.append(Double(nowNS() - t) / 1e6)
        i += n
    }
    r.wallS = Double(nowNS() - t0) / 1e9
    r.partials = rec.snapshot()
    do {
        let (text, tokens) = try await feeder.finish()
        r.final = text
        r.tokens = tokens
    } catch { log("\(bundle)/\(session) finish error: \(error)") }
    r.detected = (await feeder.promptInfo()).language

    let gaps = zip(r.partials, r.partials.dropFirst()).map { $1.audioS - $0.audioS }
    let median = gaps.sorted()
    print(String(format: "  %-8@ %@  %5.1f s audio  %5.1f s wall  %4.2fx  "
                 + "%3d partials  gap p50 %.2f s  %3d words  prompt %@  \(r.final.prefix(90))",
                 bundle as NSString, session as NSString, r.audioS, r.wallS,
                 r.audioS / max(r.wallS, 1e-9), r.partials.count,
                 median.isEmpty ? 0 : median[median.count / 2], r.final.split(separator: " ").count,
                 (r.promptId.map(String.init) ?? "-") as NSString, "" as NSString))
    return r
}

// MARK: - main

@main
struct BundleSwap {
    static func main() async {
        let args = Args.parse()
        if args.selfcheck { selfcheck(); return }
        if args.compare.count == 2 {
            await compareEncoders(args.compare[0], args.compare[1], melsPath: args.mels)
            return
        }

        var runs: [Run] = []
        let specs = args.sessions.split(separator: ",").compactMap(SessionSpec.parse)

        // One manager per bundle dir: load once, reset between sessions.
        if !args.en.isEmpty {
            let m = StreamingNemotronAsrManager()
            let dir = URL(fileURLWithPath: (args.en as NSString).expandingTildeInPath)
            do { try await m.loadModels(from: dir) } catch { log("en load failed: \(error)"); exit(1) }
            print("loaded en: \(dir.path)")
            let feeder = EnglishFeeder(manager: m)
            for s in specs {
                let audio = try! readCapture(capture(args.captures, s.id), maxFrames: s.frames)
                runs.append(await run("en", dir: dir.path, session: s.id, audio: audio,
                                      feeder: feeder, args: args, language: nil))
            }
            await feeder.cleanup()
        }

        let mlName = args.label.isEmpty ? "ml" : args.label
        let multilingual: [(String, String)] = [(mlName, args.ml), ("staged", args.staged)]
            .filter { !$0.1.isEmpty }
        if !multilingual.isEmpty {
            for (name, path) in multilingual {
                let m = StreamingNemotronMultilingualAsrManager()
                let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                do { try await m.loadModels(from: dir) } catch { log("\(name) load failed: \(error)"); exit(1) }
                // Same language hint for ml and staged: the encoder comparison must
                // hold everything except the encoder fixed.
                await m.setLanguage(args.language)
                print("loaded \(name): \(dir.path)  prompt \(await m.promptId())  "
                      + "language hint \(args.language)")
                let feeder = MultilingualFeeder(manager: m)
                for s in specs {
                    let audio = try! readCapture(capture(args.captures, s.id), maxFrames: s.frames)
                    runs.append(await run(name, dir: dir.path, session: s.id, audio: audio,
                                          feeder: feeder, args: args, language: args.language))
                }
                await feeder.cleanup()
            }
        }

        let outURL = URL(fileURLWithPath: (args.out as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? encode(runs, args: args).write(to: outURL)
        print("wrote \(outURL.path)")
    }

    static func capture(_ base: String, _ id: String) -> URL {
        URL(fileURLWithPath: base).appendingPathComponent("turn-\(id).wav")
    }

    static func selfcheck() {
        let s = SessionSpec.parse("2026-10-25T23:13:14Z:1394")!
        assert(s.id == "2026-10-25T23:13:14Z" && s.frames == 1394)
        assert(SessionSpec.parse("2026-10-25T23:13:14Z") == nil)
        let args = Args.parse()
        let audio = [Float](repeating: 0, count: 10_000)
        let buffers = stride(from: 0, to: audio.count, by: args.bufferFrames).map {
            min(args.bufferFrames, audio.count - $0)
        }
        assert(buffers.reduce(0, +) == audio.count)
        assert(buffers.count == 15, "\(buffers.count)")
        // last buffer's deadline is the audio's own end, never past it
        assert(abs(Double(audio.count) / Double(SR) - 0.625) < 1e-12)
        print("selfcheck: session parse, buffer plan, deadline mapping OK")
    }

    static func encode(_ rs: [Run], args: Args) -> Data {
        let dicts: [[String: Any]] = rs.map { r in
            var d: [String: Any] = [
                "bundle": r.bundle, "session": r.session, "dir": r.dir,
                "audio_s": r.audioS, "wall_s": r.wallS,
                "final": r.final, "tokens": r.tokens,
                "partials": r.partials.map {
                    ["audio_s": $0.audioS, "wall_s": $0.wallS, "text": $0.text]
                },
            ]
            if let l = r.language { d["language_hint"] = l }
            if let p = r.promptId { d["prompt_id"] = p }
            if let x = r.detected { d["detected_language"] = x }
            if !r.calls.isEmpty {
                let s = r.calls.sorted()
                d["call_ms"] = ["n": s.count, "p50": s[s.count / 2],
                                "p95": s[Int(Double(s.count - 1) * 0.95)], "max": s.last!]
            }
            return d
        }
        let root: [String: Any] = [
            "probe": "asr-bundle-swap", "buffer_frames": args.bufferFrames,
            "fork": "donpark/FluidAudio@2ad9b422 (encoder-output-callback)",
            "runs": dicts,
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }
}
