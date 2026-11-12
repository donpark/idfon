// Runnable check for `QuietClock` (not part of the Xcode target).
// Foundation-only, so it compiles and runs on the host:
//
//   swiftc -o /tmp/qc ios/Idfon/QuietClock.swift \
//     ios/Checks/QuietClockCheck/main.swift
//   /tmp/qc
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL:", msg); exit(1) }
    print("ok:", msg)
}

func tone(_ seconds: Double, amplitude: Float, rate: Double = 16_000) -> [Float] {
    let n = Int(seconds * rate)
    return (0..<n).map { amplitude * sinf(2 * .pi * 220 * Float($0) / Float(rate)) }
}

/// −60 dBFS noise, so the learned floor sits below a 0.05-amplitude voice.
func room(_ seconds: Double, amplitude: Float = 0.001, rate: Double = 16_000) -> [Float] {
    var rng = SystemRandomNumberGenerator()
    let n = Int(seconds * rate)
    return (0..<n).map { _ in amplitude * Float.random(in: -1...1, using: &rng) }
}

let rate = 16_000.0

// 1. A pause fires when speech goes quiet, and resumes when it comes back.
do {
    let c = QuietClock()
    var pauses = 0
    var resume: (TimeInterval, TimeInterval)?
    c.onPause = { _ in pauses += 1 }
    c.onResume = { resume = ($0, $1) }
    c.feed(room(1.0), sampleRate: rate) // learn the room
    c.begin()
    c.feed(tone(0.5, amplitude: 0.05), sampleRate: rate)
    check(pauses == 0, "speech does not pause")
    c.feed(room(0.10), sampleRate: rate)
    check(pauses == 1, "quiet starts one pause")
    check(c.quietSeconds > 0.05, "open pause is measured")
    c.feed(tone(0.10, amplitude: 0.05), sampleRate: rate)
    check(resume != nil, "speech resumes the pause")
    if let resume {
        check(abs(resume.0 - 0.10) < 0.03, "resume reports the quiet length (got \(resume.0))")
        check(resume.1 >= 0.064, "resume needs 64 ms of loud audio")
    }
    c.end()
}

// 2. No pause outside a segment (before begin, after end).
do {
    let c = QuietClock()
    var pauses = 0
    c.onPause = { _ in pauses += 1 }
    c.feed(room(0.5), sampleRate: rate)
    c.feed(room(0.5), sampleRate: rate)
    check(pauses == 0, "idle silence is not a pause")
    c.begin()
    c.feed(room(0.5), sampleRate: rate)
    check(pauses == 1, "in-segment silence is a pause")
    c.end()
    c.feed(room(0.5), sampleRate: rate)
    check(pauses == 1, "end stops pause reporting")
}

// 3. Short gaps stay short: 100 ms counts below the 240 ms early-end rule.
do {
    let c = QuietClock()
    var longest: TimeInterval = 0
    c.onResume = { quiet, _ in longest = max(longest, quiet) }
    c.feed(room(1.0), sampleRate: rate)
    c.begin()
    c.feed(tone(0.3, amplitude: 0.05) + room(0.10) + tone(0.3, amplitude: 0.05), sampleRate: rate)
    check(longest < 0.24, "a word gap stays under the early-end rule (got \(longest))")
    c.end()
}

// 4. A noisy room raises the threshold but speech is never quiet.
do {
    let c = QuietClock()
    var pauses = 0
    c.onPause = { _ in pauses += 1 }
    c.feed(room(2.0, amplitude: 0.03), sampleRate: rate) // -30 dBFS room
    c.begin()
    c.feed(tone(0.6, amplitude: 0.2), sampleRate: rate) // 16 dB over the room
    check(pauses == 0, "speech stays above a raised noise floor")
    c.feed(room(0.2, amplitude: 0.03), sampleRate: rate)
    check(pauses == 1, "the raised floor still finds real quiet")
    c.end()
}

// 5. reset() forgets the learned floor and any open pause.
do {
    let c = QuietClock()
    var pauses = 0
    c.onPause = { _ in pauses += 1 }
    c.feed(room(1.0), sampleRate: rate)
    c.begin()
    c.feed(room(0.2), sampleRate: rate)
    check(pauses == 1, "pause before reset")
    c.reset()
    check(c.quietSeconds == 0, "reset clears the open pause")
    c.begin()
    c.feed(room(0.2), sampleRate: rate)
    check(pauses == 2, "the clock still works after reset")
    c.end()
}

// 6. A sample-rate change re-frames instead of mis-timing.
do {
    let c = QuietClock()
    var pauses = 0
    c.onPause = { _ in pauses += 1 }
    c.feed(room(1.0, rate: 48_000), sampleRate: 48_000)
    c.begin()
    c.feed(tone(0.3, amplitude: 0.05, rate: 48_000), sampleRate: 48_000)
    c.feed(room(0.1, rate: 16_000), sampleRate: 16_000)
    check(pauses == 1, "48 kHz -> 16 kHz still pauses")
    c.end()
}

print("ALL OK")
