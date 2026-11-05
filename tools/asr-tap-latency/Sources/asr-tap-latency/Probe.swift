// Tap delivery through the *real* shipping ASR manager (#132 / #102).
//
// What this measures, and what it cannot: `ports/tyger-student/tap_latency.py`
// (the offline harness) stamped a frame's tap at the *encoder call's return* on a
// virtual audio clock. The product reads the tap from
// `StreamingNemotronAsrManager.setEncoderOutputCallback` (the forked FluidAudio
// hook), so every earlier number is missing whatever the manager adds around that
// call: chunk accumulation from live buffers, the native mel front-end, the actor
// hop, and - the big one - the RNNT decode that runs after the hook and, being
// serial on the same actor, delays the *next* chunk's encoder.
//
// This probe feeds recorded call audio through the manager itself, paced on a real
// device clock (or unpaced, for the arithmetic), and records one monotonic chain
// per delivered frame: audio end -> (encoder return: not exposed by the fork) ->
// callback entry -> decode end. No threshold, rule or model is touched; the only
// staged change is packaging (see stage_models.py).
//
// Usage:
//   swift run -c release asr-tap-latency \
//     --models bench-results/asr-manager-probe/models/560ms \
//     --sessions 2026-10-25T23:13:14Z:1394,2026-10-26T20:17:43Z:1114 \
//     --modes paced,unpaced --out bench-results/asr-manager-probe/probe.json
//
//   --onset        synthetic 3 s silence + 1 s noise burst: which tap row turns
//                  loud pins the manager's own frame-to-audio alignment
//   --no-callback  control run with the hook unregistered (hook path cost)
//   --selfcheck    statistics/alignment asserts, no models

import AVFoundation
import CoreML
import FluidAudio
import Foundation

// MARK: - clock

@inline(__always) func nowNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

let SR = 16_000
let FRAME_S = 0.080  // one encoder frame (subsampling 8 x 10 ms mel hop)

// MARK: - args

struct Args {
    var models = "bench-results/asr-manager-probe/models/560ms"
    var captures = ("~/Library/Application Support/Idfon/turn-captures" as NSString).expandingTildeInPath
    var sessions = "2026-10-25T23:13:14Z,2026-10-26T20:17:43Z,2026-10-26T21:13:38Z"
    var modes = ["paced", "unpaced"]
    var bufferFrames = 682  // the mic tap's 2048 @48 kHz, in 16 kHz samples
    var out = "bench-results/asr-manager-probe/probe.json"
    var onset = false
    var noCallback = false
    var selfcheck = false
    var ab = false
    var limitFrames = 0

    static func parse() -> Args {
        var a = Args()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let flag = it.next() {
            func value() -> String { it.next() ?? "" }
            switch flag {
            case "--models": a.models = value()
            case "--captures": a.captures = value()
            case "--sessions": a.sessions = value()
            case "--modes": a.modes = value().split(separator: ",").map(String.init)
            case "--buffer-frames": a.bufferFrames = Int(value()) ?? a.bufferFrames
            case "--out": a.out = value()
            case "--limit-frames": a.limitFrames = Int(value()) ?? 0
            case "--onset": a.onset = true
            case "--no-callback": a.noCallback = true
            case "--selfcheck": a.selfcheck = true
            case "--ab": a.ab = true
            default: log("unknown flag \(flag)")
            }
        }
        return a
    }
}

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// MARK: - recording

/// One hook delivery. `tEntry` is read as the callback's first statement: the fork
/// fires the hook immediately after `encoder.prediction` returns, so what the code
/// between does is cache extraction, the mel-cache copy and building the output
/// dictionary - no model call, no await.
struct Delivery {
    let g0: Int      // global frame origin the manager reported
    let n: Int       // frames delivered
    let tEntry: UInt64
    let call: Int    // index of the `process(audioBuffer:)` call it fired inside
    let names: [String]
    let tapShape: [Int]?
    let encodedShape: [Int]
    let rowEnergy: [Double]?  // --onset only
}

final class Counter: @unchecked Sendable {
    var value = 0
}

struct CallRec {
    var tStart: UInt64
    var tEnd: UInt64 = 0
    var chunks: Int = 0
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries: [Delivery] = []
    private var calls: [CallRec] = []
    private var partials: [(call: Int, t: UInt64)] = []
    private var inflight = -1
    var energyProbe = false

    func beginCall() -> Int {
        lock.lock(); defer { lock.unlock() }
        calls.append(CallRec(tStart: nowNS()))
        inflight = calls.count - 1
        return inflight
    }

    func endCall(_ index: Int) {
        let t = nowNS()
        lock.lock(); defer { lock.unlock() }
        calls[index].tEnd = t
        inflight = -1
    }

    /// The call the hook fired inside (read under the same lock as `tEntry`).
    func currentCall() -> Int {
        lock.lock(); defer { lock.unlock() }
        return inflight
    }

    func onDelivery(_ d: Delivery) {
        lock.lock(); defer { lock.unlock() }
        if d.call >= 0 { calls[d.call].chunks += 1 }
        deliveries.append(d)
    }

    func onPartial(_ t: UInt64) {
        lock.lock(); defer { lock.unlock() }
        partials.append((inflight, t))
    }

    func snapshot() -> ([Delivery], [CallRec], [(call: Int, t: UInt64)]) {
        lock.lock(); defer { lock.unlock() }
        return (deliveries, calls, partials)
    }
}

// MARK: - audio

/// 16 kHz capture -> mic channel (channel 0) as f32. The turn path is mono: the
/// manager takes one stream and the app feeds it the mic channel.
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
        for k in 0..<n { out[k] = f[0][k] }
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

/// Sleep to a monotonic deadline, spinning the last 1.5 ms: a device clock, not a
/// virtual one - the audio arrives when it arrives.
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

// MARK: - stats

func pct(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    let rank = p / 100.0 * Double(s.count - 1)
    let lo = Int(rank.rounded(.down)), hi = min(lo + 1, s.count - 1)
    return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
}

func stats(_ xs: [Double]) -> [String: Double] {
    guard !xs.isEmpty else { return ["n": 0] }
    var d: [String: Double] = ["n": Double(xs.count), "mean": xs.reduce(0, +) / Double(xs.count)]
    for p in [5.0, 50.0, 95.0] { if let v = pct(xs, p) { d["p\(Int(p))"] = v } }
    d["max"] = xs.max()!
    return d.mapValues { ($0 * 1000).rounded() / 1000 }  // ms, 3 decimals
}

/// The offline harness's per-frame number, exactly as `tap_latency.py` builds it:
/// `ready = chunk audio end + 90 ms pre-context + encode`, stamped per frame as
/// `(i + 1) * 80 ms` with i = shard frame = global + 1, so
/// `delay(k) = 490 - 80 k + enc` for the k-th of a chunk's 7 rows.
/// `encMS` is its measured per-chunk encode (both ears: 23.6-27.8 ms).
func offlineDelayMS(k: Int, encMS: Double) -> Double { 490.0 - 80.0 * Double(k) + encMS }

func selfcheck() {
    assert(abs(Double(7) * FRAME_S - 0.56) < 1e-12)
    let off = (0..<700).map { offlineDelayMS(k: $0 % 7, encMS: 24.0) }
    assert(abs(pct(off, 50)! - 274) < 20, "p50 \(pct(off, 50)!)")
    assert(abs(pct(off, 95)! - 514) < 20, "p95 \(pct(off, 95)!)")
    assert(pct([1, 2, 3, 4], 50) == 2.5)
    print("selfcheck: frame mapping, offline formula, percentiles OK")
}

// MARK: - one replay

struct SessionResult {
    var session = ""
    var mode = ""
    var seconds = 0.0
    var frames = 0
    var chunks = 0
    var produced = 0
    var consumed = 0
    var pendingMax = 0
    var dropped = 0
    var callMS: [String: Double] = [:]   // per-`process` wall time (mel+enc+decode)
    var byRow: [String: [String: Double]] = [:]
    var delay: [String: Double] = [:]
    var chunkLag: [String: Double] = [:]
    var preHook: [String: Double] = [:]
    var postHook: [String: Double] = [:]
    var decode: [String: Double] = [:]
    var decodeChunks = 0
    var vsOfflineAll: [String: Double] = [:]
    var vsOfflineByRow: [String: [String: Double]] = [:]
    var transcript = ""
    var tokens = 0
    var tokenLastS = 0.0
    var deliveries: [[Double]] = []
    var rowEnergy: [[Double]] = []
    var loadS = 0.0
    var totalCallMS = 0.0
    var argFrames = 0
    var originBase = 0
    var originStepOK = true
    var tapPresent = false
}

func run(session: String, frames: Int, audio: [Float], mode: String,
         manager: StreamingNemotronAsrManager, rec: Recorder, args: Args,
         loadS: Double) async -> SessionResult {
    var r = SessionResult()
    r.session = session
    r.mode = mode
    r.loadS = loadS
    r.argFrames = frames
    r.seconds = Double(frames) * FRAME_S

    let paced = mode == "paced"
    let capacity: AsyncStream<AVAudioPCMBuffer>.Continuation.BufferingPolicy =
        paced ? .bufferingNewest(64) : .unbounded  // app-faithful / arithmetic-only
    let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: capacity)

    let bufferFrames = args.bufferFrames
    let total = audio.count
    let t0 = nowNS()
    let drops = Counter()
    let producer = Task {
        var i = 0
        while i < total {
            let n = min(bufferFrames, total - i)
            if paced {
                let audioEnd = Double(i + n) / Double(SR)
                await waitUntil(t0 + UInt64(audioEnd * 1e9))
            }
            // Counted, not ignored: a drop would break the frame/audio mapping.
            if case .dropped = cont.yield(makeBuffer(audio[i..<(i + n)])) { drops.value += 1 }
            i += n
        }
        cont.finish()
    }

    // Consumer: one serial feed, exactly the app's shape (await process per buffer).
    var consumed = 0
    for await buf in stream {
        let call = rec.beginCall()
        do { _ = try await manager.process(audioBuffer: buf) } catch { log("process error: \(error)") }
        rec.endCall(call)
        consumed += 1
    }
    await producer.value
    r.consumed = consumed
    r.dropped = drops.value
    r.produced = consumed + r.dropped
    r.pendingMax = r.dropped

    var (deliveries, calls, partials) = rec.snapshot()
    // `tapFrameOrigin` survives `reset()` in the fork (only `cleanup()` clears it),
    // so a per-session audio clock has to subtract this run's baseline origin.
    let originBase = deliveries.first?.g0 ?? 0
    r.originBase = originBase
    r.originStepOK = zip(deliveries, deliveries.dropFirst()).allSatisfy {
        $1.g0 == $0.g0 + $0.n
    }
    deliveries = deliveries.map {
        Delivery(g0: $0.g0 - originBase, n: $0.n, tEntry: $0.tEntry, call: $0.call,
                 names: $0.names, tapShape: $0.tapShape, encodedShape: $0.encodedShape,
                 rowEnergy: $0.rowEnergy)
    }
    r.chunks = deliveries.count
    r.frames = deliveries.reduce(0) { $0 + $1.n }
    // A timing number must not come from a manager path that lost the tap output.
    if let first = deliveries.first {
        r.tapPresent = first.tapShape == [1, 1024, 7] && first.names.contains("tap_l4")
        if !r.tapPresent {
            log("WARNING: first delivery had no tap_l4 [1,1024,7] (names \(first.names), "
                + "shape \(first.tapShape ?? [])) — these timings are not the tap path")
        }
    }
    r.totalCallMS = calls.reduce(0.0) { $0 + Double($1.tEnd - $1.tStart) / 1e6 }
    r.callMS = stats(calls.filter { $0.tEnd > $0.tStart }.map { Double($0.tEnd - $0.tStart) / 1e6 })

    // A frame's audio ends at t0 + (g + 1) * 80 ms: the manager consumes audio
    // contiguously from the stream's start, 7 frames per 560 ms chunk.
    func audioEnd(_ g: Int) -> UInt64 { t0 + UInt64((Double(g + 1) * FRAME_S) * 1e9) }
    func ms(_ a: UInt64, _ b: UInt64) -> Double { (Double(a) - Double(b)) / 1e6 }

    var partialAt: [Int: UInt64] = [:]
    for p in partials where partialAt[p.call] == nil { partialAt[p.call] = p.t }

    var rows: [Int: [Double]] = [:]
    var all: [Double] = [], lags: [Double] = [], off: [Double] = []
    var pre: [Double] = [], post: [Double] = [], dec: [Double] = []
    for d in deliveries {
        lags.append(ms(d.tEntry, audioEnd(d.g0 + d.n - 1)))
        for k in 0..<d.n {
            let v = ms(d.tEntry, audioEnd(d.g0 + k))
            rows[k, default: []].append(v)
            all.append(v)
            off.append(v - offlineDelayMS(k: k, encMS: 24.0))
        }
        r.deliveries.append([Double(d.g0), Double(d.n), ms(d.tEntry, audioEnd(d.g0 + d.n - 1))])
        if let e = d.rowEnergy { r.rowEnergy.append(e) }
        if d.call >= 0 {
            let c = calls[d.call]
            pre.append(ms(d.tEntry, c.tStart))
            post.append(ms(c.tEnd, d.tEntry))
            if let p = partialAt[d.call] { dec.append(ms(p, d.tEntry)) }
        }
    }
    r.delay = stats(all)
    r.chunkLag = stats(lags)
    r.byRow = Dictionary(uniqueKeysWithValues: rows.map { ("k\($0.key)", stats($0.value)) })
    r.preHook = stats(pre)
    r.postHook = stats(post)
    r.decode = stats(dec)
    r.decodeChunks = dec.count
    r.vsOfflineAll = stats(off)
    for (k, xs) in rows {
        r.vsOfflineByRow["k\(k)"] = stats(xs.map { $0 - offlineDelayMS(k: k, encMS: 24.0) })
    }
    return r
}

// MARK: - main

@main
struct Probe {
    static func main() async {
        let args = Args.parse()
        if args.selfcheck { selfcheck(); return }

        let modelsURL = URL(fileURLWithPath: (args.models as NSString).expandingTildeInPath)
        let manager = StreamingNemotronAsrManager()
        let loadStart = nowNS()
        do { try await manager.loadModels(from: modelsURL) } catch {
            log("load failed: \(error)")
            exit(1)
        }
        let loadS = Double(nowNS() - loadStart) / 1e9
        print(String(format: "loaded %@ in %.1f s", modelsURL.lastPathComponent, loadS))

        var results: [SessionResult] = []

        if args.ab {
            // Interleaved A/B on one slice: does the *hook path* cost anything?
            // Same process, same audio, alternating, so host load is shared.
            let url = URL(fileURLWithPath: args.captures)
                .appendingPathComponent("turn-2026-10-26T20:17:43Z.wav")
            let audio = try! readCapture(url, maxFrames: 500)
            print("\n== hook A/B: 3 x (hook, no hook) on a 40 s slice, paced")
            for rep in 0..<3 {
                for hook in [true, false] {
                    await manager.reset()
                    let rec = Recorder()
                    await register(manager, rec, enabled: hook)
                    let r = await run(session: "ab", frames: 500, audio: audio,
                                      mode: "paced", manager: manager, rec: rec,
                                      args: args, loadS: loadS)
                    _ = try? await manager.finish()
                    let chunks = r.chunks > 0 ? r.chunks : r.argFrames / 7
                    print(String(format: "  rep %d hook %-5@  %3d chunks  %8.1f ms total  "
                                 + "%6.2f ms/chunk  (decode p50 %@ ms)",
                                 rep, (hook ? "on" : "off") as NSString, chunks,
                                 r.totalCallMS, r.totalCallMS / Double(max(1, chunks)),
                                 r.decode["p50"].map { String(format: "%.1f", $0) } ?? "-"))
                }
            }
            return
        }

        if args.onset {
            var audio = [Float](repeating: 0, count: 3 * SR)
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<SR { audio.append(Float.random(in: -0.3...0.3, using: &rng)) }
            audio.append(contentsOf: [Float](repeating: 0, count: SR))
            let rec = Recorder()
            rec.energyProbe = true
            await register(manager, rec, enabled: !args.noCallback)
            var r = await run(session: "onset", frames: audio.count / 1280, audio: audio,
                              mode: "unpaced", manager: manager, rec: rec, args: args, loadS: loadS)
            r.transcript = (try? await manager.finish()) ?? ""
            results.append(r)
            printOnset(r)
        } else {
            for spec in args.sessions.split(separator: ",") {
                // "id:frames" - the id itself contains ':'
                let parts = spec.split(separator: ":")
                let id = parts.count > 1 && Int(parts.last!) != nil
                    ? parts.dropLast().joined(separator: ":") : String(spec)
                let frames = parts.count > 1 ? (Int(parts.last!) ?? 0) : args.limitFrames
                let url = URL(fileURLWithPath: args.captures)
                    .appendingPathComponent("turn-\(id).wav")
                let audio: [Float]
                do { audio = try readCapture(url, maxFrames: frames) } catch {
                    log("no capture \(url.path): \(error)"); continue
                }
                for mode in args.modes {
                    await manager.reset()
                    let rec = Recorder()
                    await register(manager, rec, enabled: !args.noCallback)
                    var r = await run(session: id, frames: frames, audio: audio, mode: mode,
                                      manager: manager, rec: rec, args: args, loadS: loadS)
                    do {
                        let (text, timings) = try await manager.finishWithTokenTimings()
                        r.transcript = text
                        r.tokens = timings.count
                        r.tokenLastS = timings.last?.startTime ?? 0
                    } catch { log("finish error: \(error)") }
                    results.append(r)
                    printRow(r)
                }
            }
        }

        let outURL = URL(fileURLWithPath: (args.out as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? encode(results, args: args).write(to: outURL)
        print("wrote \(outURL.path)")
    }

    static func register(_ manager: StreamingNemotronAsrManager, _ rec: Recorder,
                         enabled: Bool) async {
        guard enabled else {
            await manager.setEncoderOutputCallback(nil)
            await manager.setPartialCallback { _ in }
            return
        }
        await manager.setEncoderOutputCallback { outputs, range, origin in
            let t = nowNS()  // <- callback entry
            rec.onDelivery(Delivery(
                g0: origin, n: range.count, tEntry: t, call: rec.currentCall(),
                names: Array(outputs.keys),
                tapShape: outputs["tap_l4"]?.shape.map { $0.intValue },
                encodedShape: outputs["encoded"]?.shape.map { $0.intValue } ?? [],
                rowEnergy: rec.energyProbe ? outputs["tap_l4"].flatMap(rowNorms) : nil))
        }
        await manager.setPartialCallback { _ in rec.onPartial(nowNS()) }
    }

    static func printOnset(_ r: SessionResult) {
        // Onset sample = 3.0 s -> frame 37 ([2960, 3040) ms). Row 37 is the first
        // loud row iff a frame's audio ends at (g + 1) * 80 ms.
        var norm: [Int: Double] = [:]
        for (i, d) in r.deliveries.enumerated() where i < r.rowEnergy.count {
            let g0 = Int(d[0])
            for (j, v) in r.rowEnergy[i].enumerated() { norm[g0 + j] = v }
        }
        guard !norm.isEmpty else { print("onset: no deliveries"); return }
        let base = pct((2..<7).compactMap { norm[$0] }.map { _ in 1.0 }, 50) ?? 1.0
        _ = base
        // first row whose direction departs from silence by more than 0.02
        let firstLoud = (20..<min(60, norm.keys.max()! + 1)).first { (norm[$0] ?? 1) < 0.98 }
        print("\n== onset: noise from 3.000 s = frame 37 (shipping decoder/joint/tokenizer)")
        print("  rows 34-44, cos(tap row, chunk-0 silence baseline):")
        for k in 34..<min(45, norm.keys.max()! + 1) {
            print(String(format: "  row %2d  cos %7.4f", k, norm[k] ?? 0))
        }
        print("  transcript on noise: \"\(r.transcript.prefix(80))\"")
    }

    static func printRow(_ r: SessionResult) {
        print("\n== \(r.session) [\(r.mode)] \(Int(r.seconds)) s  \(r.frames) frames  "
              + "\(r.chunks) chunks  produced \(r.produced) consumed \(r.consumed) "
              + "dropped \(r.dropped)  origin base \(r.originBase) "
              + "step \(r.originStepOK ? "exact" : "BROKEN")"
              + "  tap_l4 \(r.tapPresent ? "[1,1024,7]" : "MISSING")")
        func line(_ name: String, _ s: [String: Double]) {
            guard let n = s["n"], n > 0 else { return }
            print(String(format: "  %-30@ n %6.0f  p50 %8.2f  p95 %8.2f  max %8.2f  ms",
                         name as NSString, n, s["p50"] ?? 0, s["p95"] ?? 0, s["max"] ?? 0))
        }
        line("callback - frame audio end", r.delay)
        line("callback - chunk audio end", r.chunkLag)
        line("per-process wall (call)", r.callMS)
        line("pre-hook (t_cb - t_start)", r.preHook)
        line("post-hook (end - t_cb)", r.postHook)
        line("decode (partial - t_cb)", r.decode)
        line("measured - offline", r.vsOfflineAll)
        var byRow: [String] = []
        for k in 0..<7 {
            if let p = r.byRow["k\(k)"]?["p50"] { byRow.append(String(format: "k%d %.0f", k, p)) }
        }
        print("  by row p50: \(byRow.joined(separator: "  "))")
        print("  transcript: \"\(r.transcript.prefix(160))\"  (\(r.tokens) tokens)")
    }

    static func encode(_ rs: [SessionResult], args: Args) -> Data {
        var sessions: [[String: Any]] = []
        for r in rs {
            var d: [String: Any] = [
                "session": r.session, "mode": r.mode, "seconds": r.seconds,
                "frames": r.frames, "chunks": r.chunks, "produced": r.produced,
                "consumed": r.consumed, "dropped": r.dropped,
                "delay_ms": r.delay, "chunk_lag_ms": r.chunkLag,
                "call_wall_ms": r.callMS, "pre_hook_ms": r.preHook,
                "post_hook_ms": r.postHook, "decode_ms": r.decode,
                "decode_chunks": r.decodeChunks, "by_row_ms": r.byRow,
                "vs_offline_ms": r.vsOfflineAll, "vs_offline_by_row": r.vsOfflineByRow,
                "total_call_ms": r.totalCallMS, "arg_frames": r.argFrames,
                "origin_base": r.originBase, "origin_step_ok": r.originStepOK,
                "tap_l4_present": r.tapPresent,
                "transcript": r.transcript, "tokens": r.tokens,
                "token_last_s": r.tokenLastS, "load_s": r.loadS,
                "deliveries": r.deliveries,
            ]
            if !r.rowEnergy.isEmpty { d["row_energy"] = r.rowEnergy }
            sessions.append(d)
        }
        let root: [String: Any] = [
            "probe": "asr-tap-latency", "models": args.models,
            "buffer_frames": args.bufferFrames, "hook": !args.noCallback,
            "fork": "donpark/FluidAudio@2ad9b422 (encoder-output-callback)",
            "offline_enc_ms": 24.0, "sessions": sessions,
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }
}

func rowNorms(_ a: MLMultiArray) -> [Double] {
    // tap_l4 [1, 1024, T] -> per-frame cosine to the *first chunk's* rows (silence
    // in --onset). L2 norm alone is insensitive: the tap of silence and of noise
    // differ in direction, not in magnitude (~225 both).
    let dim = a.shape[1].intValue
    let t = a.shape[2].intValue
    var rows = [[Double]]()
    for j in 0..<t {
        var v = [Double](repeating: 0, count: dim)
        for c in 0..<dim { v[c] = a[[0, c, j] as [NSNumber]].doubleValue }
        rows.append(v)
    }
    if Debug.baseline == nil {
        Debug.baseline = (0..<dim).map { c in
            rows.reduce(0.0) { $0 + $1[c] } / Double(rows.count)
        }
        print("  onset baseline set from chunk 0 (\(t) rows, \(dim)-d)")
    }
    let base = Debug.baseline!
    let baseNorm = base.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
    return rows.map { r in
        let dot = zip(r, base).reduce(0.0) { $0 + $1.0 * $1.1 }
        let norm = r.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        return dot / max(norm * baseNorm, 1e-9)
    }
}

enum Debug { nonisolated(unsafe) static var baseline: [Double]? }
