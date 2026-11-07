// TurnReplayStoreCheck: the per-turn replay cache's file format, trim, and
// eviction (#202 P1/P2), run as
// `swiftc -o /tmp/turnreplaycheck <app>/TurnReplayStore.swift <app>/Checks/TurnReplayStoreCheck/main.swift && /tmp/turnreplaycheck`.

import Foundation

func check(_ ok: Bool, _ what: String) {
    if ok {
        print("ok  \(what)")
    } else {
        print("FAIL \(what)")
        exit(1)
    }
}

// wavMono: header fields and sample roundtrip.
let samples: [Float] = [0, 0.5, -0.5, 1.0, -1.0]
guard let wav = TurnReplayStore.wavMono(samples: samples, rate: 24_000) else {
    print("FAIL wavMono returns bytes")
    exit(1)
}
check(wav.count == 44 + samples.count * 2, "wav size")
check(String(data: wav.subdata(in: 0..<4), encoding: .utf8) == "RIFF", "wav RIFF")
check(String(data: wav.subdata(in: 8..<12), encoding: .utf8) == "WAVE", "wav WAVE")
let rate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
check(rate == 24_000, "wav rate")
let channels = wav.subdata(in: 22..<24).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
check(channels == 1, "wav mono")
let mid = wav.subdata(in: 46..<48).withUnsafeBytes { Int16(bitPattern: $0.loadUnaligned(as: UInt16.self)) }
check(abs(Float(mid) / 32767 - 0.5) < 0.001, "wav sample roundtrip")
check(TurnReplayStore.wavMono(samples: [], rate: 24_000) == nil, "empty samples rejected")

// trim: silence at both ends goes, speech stays.
let padded = [Float](repeating: 0, count: 100) + [0.5, -0.5] + [Float](repeating: 0, count: 100)
check(TurnReplayStore.trim(padded) == [0.5, -0.5], "trim strips both ends")
check(TurnReplayStore.trim([0, 0, 0]).isEmpty, "trim of silence is empty")

// fileName: turn ids stay readable; odd characters cannot escape the dir.
check(TurnReplayStore.fileName("call-x-3-agent") == "call-x-3-agent.wav", "plain turn id")
check(!TurnReplayStore.fileName("../evil id").contains("/"), "unsafe characters neutralized")

// evict: stale-out by age, then oldest-out over budget (whole files only).
let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("turnreplay-check-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
func put(_ name: String, _ bytes: Int, _ age: TimeInterval) {
    let url = dir.appendingPathComponent(name)
    try! Data(count: bytes).write(to: url)
    try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                           ofItemAtPath: url.path)
}
put("a.wav", 1000, 30)
put("b.wav", 1000, 20)
put("c.wav", 1000, 10)
put("stale.wav", 1000, 40 * 24 * 3600)
TurnReplayStore.evict(in: dir, budgetBytes: 2500, maxAge: 30 * 24 * 3600)
let left = (try! FileManager.default.contentsOfDirectory(atPath: dir.path)).sorted()
check(left == ["b.wav", "c.wav"], "evict keeps newest under budget and drops stale")
try! FileManager.default.removeItem(at: dir)

// store/url/discard roundtrip (cache-class dir, cleaned up after).
let key = "turnreplay-check-\(UUID().uuidString)"
check(TurnReplayStore.store(turnKey: key, samples: [0.5, -0.5], rate: 24_000) != nil, "store writes")
check(TurnReplayStore.url(for: key) != nil, "url finds the stored turn")
TurnReplayStore.discard(turnKey: key)
check(TurnReplayStore.url(for: key) == nil, "discard removes it")

print("all ok")
