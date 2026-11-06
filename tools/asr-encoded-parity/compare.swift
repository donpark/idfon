// Encoder-vs-encoder parity on identical real mel windows (#132).
//
// Answers one question with no manager in the loop: given the same mel, the same
// prompt and each encoder's own caches, do two Core ML encoders emit the same
// `encoded` frames? This is the corrected form of `asr-bundle-swap --compare`,
// which seeded `cache_len = 0` (the manager seeds 1) and only ran 4 chunks, i.e.
// entirely inside the cold-start transient.
//
// Reported: per-chunk cosine and max|d|, an overall and per-bucket summary, a
// +-1 row-shift scan (a framing/row-origin error shows up as "cos is higher one
// row over"), per row-in-chunk cos p05, and each model's `cache_len_out`
// trajectory (7 rows/call vs 8 is the structural difference between the
// published conversion and ours).
//
//   swift tools/asr-encoded-parity/compare.swift \
//     --a bundle/encoder.mlmodelc --b ours.mlpackage --mels mels.f32 \
//     --prompt 0 --json out.json
//
// `--mels` is [chunks,1,128,65] float32 written by tools/asr-bundle-swap/mels.py.
// CPU only: numerics, not ANE placement.

import CoreML
import Darwin
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

struct Opts {
    var a = "", b = "", mels = "", json = ""
    var prompt = 0
    var seedLen = 1
    var labelA = "A", labelB = "B"
}

func parse() -> Opts {
    var o = Opts()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let f = it.next() {
        func v() -> String { it.next() ?? "" }
        switch f {
        case "--a": o.a = v()
        case "--b": o.b = v()
        case "--mels": o.mels = v()
        case "--json": o.json = v()
        case "--prompt": o.prompt = Int(v()) ?? 0
        case "--seed-len": o.seedLen = Int(v()) ?? 1
        case "--label-a": o.labelA = v()
        case "--label-b": o.labelB = v()
        case "--selfcheck": break
        default: FileHandle.standardError.write("unknown flag \(f)\n".data(using: .utf8)!)
        }
    }
    return o
}

let opts = parse()

let melFrames = 65, cacheDepth = 42, rowsPerChunk = 7
let melShape = [1, 128, melFrames]
let chShape = [1, 24, cacheDepth, 1024]
let tmShape = [1, 24, 1024, 8]

if CommandLine.arguments.contains("--selfcheck") {
    // the report arithmetic only: token-free, no models
    let a: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    let b: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    precondition(abs(cos(a, b, a.count) - 1.0) < 1e-12)
    precondition(maxAbs(a, b, a.count) == 0)
    precondition(pct([1, 2, 3, 4], 50) == 2.5)
    let chunk: [Float] = (0..<(1024 * rowsPerChunk)).map { Float($0) }
    precondition(row(chunk, 0)[1] == Float(rowsPerChunk))   // c=1, r=0 -> index 7
    precondition(row(chunk, 3)[1] == Float(rowsPerChunk + 3))
    print("selfcheck: cosine, max|d|, percentile, row layout OK")
    exit(0)
}


func zeros(_ shape: [Int]) -> MLMultiArray {
    try! MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
}
func int1(_ v: Int) -> MLMultiArray {
    let a = try! MLMultiArray(shape: [1], dataType: .int32)
    a[0] = NSNumber(value: v)
    return a
}
func floats(_ a: MLMultiArray) -> [Float] {
    try! a.withUnsafeBufferPointer(ofType: Float.self) { Array($0[0..<$0.count]) }
}
func cos(_ a: [Float], _ b: [Float], _ n: Int) -> Double {
    var d = 0.0, na = 0.0, nb = 0.0
    for i in 0..<n { let x = Double(a[i]), y = Double(b[i]); d += x * y; na += x * x; nb += y * y }
    return d / max((na * nb).squareRoot(), 1e-12)
}
func maxAbs(_ a: [Float], _ b: [Float], _ n: Int) -> Double {
    var m = 0.0
    for i in 0..<n { m = max(m, abs(Double(a[i]) - Double(b[i]))) }
    return m
}
func pct(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted(); let r = p / 100 * Double(s.count - 1)
    let lo = Int(r), hi = min(lo + 1, s.count - 1)
    return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
}

struct Enc {
    let model: MLModel
    var ch = zeros(chShape), tm = zeros(tmShape)
    var len: MLMultiArray
    let name: String

    init(_ path: String, seed: Int) {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if url.pathExtension == "mlpackage" {  // MLModel needs a compiled model
            url = try! MLModel.compileModel(at: url)
        }
        model = try! MLModel(contentsOf: url, configuration: cfg)
        len = int1(seed)
        name = (path as NSString).lastPathComponent
        let spec = model.modelDescription
        let want = ["mel", "mel_length", "cache_channel", "cache_time", "cache_len", "prompt_id"]
        for k in want where spec.inputDescriptionsByName[k] == nil {
            FileHandle.standardError.write("\(name): missing input \(k)\n".data(using: .utf8)!)
            exit(2)
        }
        if let enc = spec.outputDescriptionsByName["encoded"]?.multiArrayConstraint {
            print("\(name): encoded \(enc.shape.map { $0.intValue }) \(enc.dataType.rawValue)")
        }
        print("\(name): prompt_id input \(spec.inputDescriptionsByName["prompt_id"] != nil)")
    }

    mutating func call(_ mel: MLMultiArray, prompt: Int) -> (MLMultiArray, MLMultiArray) {
        let input = try! MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: mel),
            "mel_length": MLFeatureValue(multiArray: int1(melFrames)),
            "cache_channel": MLFeatureValue(multiArray: ch),
            "cache_time": MLFeatureValue(multiArray: tm),
            "cache_len": MLFeatureValue(multiArray: len),
            "prompt_id": MLFeatureValue(multiArray: int1(prompt)),
        ])
        let out = try! model.prediction(from: input)
        let enc = out.featureValue(for: "encoded")!.multiArrayValue!
        let chOut = out.featureValue(for: "cache_channel_out")!.multiArrayValue!
        let tmOut = out.featureValue(for: "cache_time_out")!.multiArrayValue!
        let lenOut = out.featureValue(for: "cache_len_out")!.multiArrayValue!
        ch = chOut; tm = tmOut; len = lenOut
        return (enc, chOut)
    }
}

// ---- mels
let raw = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: (opts.mels as NSString).expandingTildeInPath)))
let nMel = 128 * melFrames * 4
let chunks = raw.count / nMel
let allFloats = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
var mels: [MLMultiArray] = []
for k in 0..<chunks {
    let m = zeros(melShape)
    try! m.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
        for i in 0..<(128 * melFrames) { p[i] = allFloats[k * 128 * melFrames + i] }
    }
    mels.append(m)
}
print("mels: \(chunks) chunks from \(opts.mels)")

var A = Enc(opts.a, seed: opts.seedLen)
var B = Enc(opts.b, seed: opts.seedLen)
if A.name == B.name { print("warning: both paths resolve to \(A.name)") }

var perChunk: [(cos: Double, maxd: Double, cacheCos: Double)] = []
var encA: [[Float]] = []   // [chunk][1024*7], layout: channel-major per row (as stored)
var encB: [[Float]] = []
var lensA: [Int] = [], lensB: [Int] = []

for k in 0..<chunks {
    let (ea, ca) = A.call(mels[k], prompt: opts.prompt)
    let (eb, cb) = B.call(mels[k], prompt: opts.prompt)
    let fa = floats(ea), fb = floats(eb)
    let n = min(fa.count, fb.count)
    encA.append(fa); encB.append(fb)
    lensA.append(A.len[0].intValue); lensB.append(B.len[0].intValue)
    perChunk.append((cos(fa, fb, n), maxAbs(fa, fb, n), cos(floats(ca), floats(cb), floats(ca).count)))
}

// rows: encoded is [1,1024,7] channel-major, so frame r of channel c is c*7 + r
func row(_ chunk: [Float], _ r: Int) -> [Float] { (0..<1024).map { chunk[$0 * rowsPerChunk + r] } }
func rowCos(_ ca: [[Float]], _ cb: [[Float]], shift: Int) -> [Double] {
    // compare A row r with B row r+shift, per chunk
    var out: [Double] = []
    for k in 0..<chunks {
        for r in 0..<rowsPerChunk {
            let rb = r + shift
            if rb < 0 || rb >= rowsPerChunk { continue }
            let a = row(encA[k], r), b = row(encB[k], rb)
            out.append(cos(a, b, 1024))
        }
    }
    return out
}

let flatCos = perChunk.map { $0.cos }
let warm = flatCos.count > 6 ? Array(flatCos.dropFirst(6)) : flatCos
print("\n== \(opts.labelA) vs \(opts.labelB), prompt \(opts.prompt), cache_len seed \(opts.seedLen)")
print("per chunk (encoded):")
for (k, p) in perChunk.enumerated() {
    print(String(format: "  chunk %2d  cos %.8f  max|d| %.3e  cache_channel cos %.6f  len %d/%d",
                 k, p.cos, p.maxd, p.cacheCos, lensA[k], lensB[k]))
}
print(String(format: "all chunks: cos p50 %.8f  p05 %.8f  min %.8f  max|d| %.3e",
             pct(flatCos, 50), pct(flatCos, 5), flatCos.min() ?? 0,
             perChunk.map { $0.maxd }.max() ?? 0))
if flatCos.count > 6 {
    print(String(format: "warm (>=chunk 6): cos p50 %.8f  p05 %.8f  min %.8f",
                 pct(warm, 50), pct(warm, 5), warm.min() ?? 0))
} else {
    print("warm: n/a (fewer than 7 chunks)")
}

print("\nrow-shift scan (A row r vs B row r+shift):")
for s in [-1, 0, 1] {
    let c = rowCos(encA, encB, shift: s)
    print(String(format: "  shift %+d: cos p50 %.8f  p05 %.8f  min %.8f",
                 s, pct(c, 50), pct(c, 5), c.min() ?? 0))
}
print("\nper row-in-chunk cos (A row r vs B row r):")
for r in 0..<rowsPerChunk {
    let c = rowCos(encA, encB, shift: 0).enumerated().filter { $0.offset % rowsPerChunk == r }.map { $0.element }
    print(String(format: "  row %d: cos p50 %.8f  p05 %.8f  min %.8f", r, pct(c, 50), pct(c, 5), c.min() ?? 0))
}
print("\ncache_len_out: A \(lensA.prefix(10)) … last \(lensA.last ?? 0); "
      + "B \(lensB.prefix(10)) … last \(lensB.last ?? 0)")

var json: [String: Any] = [
    "a": opts.a, "b": opts.b, "prompt": opts.prompt, "seed_cache_len": opts.seedLen,
    "chunks": chunks,
    "all": ["cos_p50": pct(flatCos, 50), "cos_p05": pct(flatCos, 5),
            "cos_min": flatCos.min() ?? 0, "max_abs": perChunk.map { $0.maxd }.max() ?? 0],
    "warm": ["cos_p50": pct(warm, 50), "cos_p05": pct(warm, 5), "cos_min": warm.min() ?? 0],
    "per_chunk": perChunk.enumerated().map { ["chunk": $0.offset, "cos": $0.element.cos,
        "max_abs": $0.element.maxd, "cache_channel_cos": $0.element.cacheCos,
        "len_a": lensA[$0.offset], "len_b": lensB[$0.offset]] as [String: Any] },
    "cache_len_out_a": lensA, "cache_len_out_b": lensB,
]
if !opts.json.isEmpty {
    // non-finite doubles are not valid JSON; the stdout table is the record
    if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
       (try? data.write(to: URL(fileURLWithPath: opts.json))) != nil {
        print("\nwrote \(opts.json)")
    } else {
        print("\n(json not written: non-finite value; see the table above)")
    }
}
