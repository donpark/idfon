// TurnTapCheck: the device-rate -> 16 kHz resampler + hop accumulation, run as
// `swiftc -o /tmp/turntapcheck mac/Sources/Idfon/TurnTap.swift mac/Checks/TurnTapCheck/main.swift && /tmp/turntapcheck`.
// Feeds sines at two device rates in odd chunks; checks hop counts and that the
// tone survives the resample (zero crossings).
import AVFAudio
import Foundation

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok  \(what)")
    } else {
        print("FAIL \(what)")
        exit(1)
    }
}

func run(rate: Double) -> (hops: Int, crossings: Int, hopSize: Int) {
    let hopSize = 100 // small hops so the check runs on tiny inputs
    var hops: [[Float]] = []
    let tap = TurnTap(hopSize: hopSize)
    tap.onHop = { hops.append($0) }
    let total = Int(rate * 0.5) // 0.5 s of 440 Hz
    let freq = 440.0
    var samples = [Float](repeating: 0, count: total)
    for i in 0..<total {
        samples[i] = Float(sin(2 * Double.pi * freq * Double(i) / rate))
    }
    var i = 0
    while i < total {
        let n = min(Int.random(in: 64...512), total - i)
        tap.feed(Array(samples[i..<(i + n)]), rate: rate)
        i += n
    }
    // zero crossings in the middle hop (steady state)
    let mid = hops[hops.count / 2]
    var crossings = 0
    for j in 1..<mid.count where (mid[j - 1] < 0) != (mid[j] < 0) {
        crossings += 1
    }
    return (hops.count, crossings, hopSize)
}

for rate in [48_000.0, 44_100.0] {
    let (hops, crossings, hopSize) = run(rate: rate)
    // 0.5 s at 16 kHz = 8000 samples = 80 hops of 100; converter latency may
    // hold back less than one hop's worth
    let expected = Int(0.5 * 16000) / hopSize
    check(abs(hops - expected) <= 1, "hop count at \(Int(rate)) Hz: \(hops) (want ~\(expected))")
    // 100 samples @16 kHz = 6.25 ms of 440 Hz ≈ 5.5 crossings
    check(abs(crossings - 6) <= 3, "tone survives at \(Int(rate)) Hz: \(crossings) crossings (want ~5-6)")
}
print("ALL OK")
