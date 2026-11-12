// Runnable check for `VoicePromptSegmenter` (not part of the Xcode target).
// The file is Foundation-only, so it compiles and runs on the host:
//
//   swiftc -o /tmp/vpscheck ios/Idfon/VoicePromptSegmenter.swift \
//     ios/Idfon/QuietClock.swift ios/Idfon/Automation.swift ios/Idfon/IdfonLog.swift \
//     ios/Checks/VoicePromptSegmenterCheck/main.swift
//   /tmp/vpscheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

// The quiet clock's early end is opt-in; this check exercises it.
setenv("IDFON_QUIET_END", "1", 1)

func check(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL:", msg); exit(1) }
    print("ok:", msg)
}

// Volatile partials accumulate but never commit.
let s = VoicePromptSegmenter()
var commits: [String] = []
var partials: [String] = []
s.onCommit = { commits.append($0) }
s.onPartial = { partials.append($0) }
s.handle("hello", isFinal: false)
check(commits.isEmpty, "partial does not commit")
check(partials == ["hello"], "partial is reported")

// A final result commits immediately.
s.handle("hello there", isFinal: true)
check(commits == ["hello there"], "final commits")

// A late final for the same segment is deduped.
s.handle("hello there", isFinal: true)
check(commits == ["hello there"], "duplicate final is deduped")

// The next segment commits.
s.handle("second turn", isFinal: true)
check(commits == ["hello there", "second turn"], "next segment commits")

// Disabled ignores everything (mic paused while the agent speaks).
var muted: [String] = []
s.onCommit = { muted.append($0) }
s.setEnabled(false)
s.handle("while speaking", isFinal: true)
check(muted.isEmpty, "disabled segmenter ignores a final")
s.setEnabled(true)

// Gap fallback: a partial with no final commits after `gap` seconds.
let g = VoicePromptSegmenter(gap: 0.2)
var gcommits: [String] = []
g.onCommit = { gcommits.append($0) }
g.start()
g.handle("gap text", isFinal: false)
check(gcommits.isEmpty, "gap text not committed before the gap elapses")
RunLoop.current.run(until: Date().addingTimeInterval(0.8))
check(gcommits == ["gap text"], "gap fallback commits the accumulated partial")
g.stop()

// clear() drops an uncommitted partial.
var ccommits: [String] = []
let c = VoicePromptSegmenter(gap: 0.2)
c.onCommit = { ccommits.append($0) }
c.start()
c.handle("stale", isFinal: false)
c.clear()
RunLoop.current.run(until: Date().addingTimeInterval(0.8))
check(ccommits.isEmpty, "cleared partial is not committed")
c.stop()

// Early end: 240 ms of measured quiet commits before the text gap. The audio
// helpers mirror QuietClockCheck (a 220 Hz voice over a -60 dBFS room).
func checkTone(_ seconds: Double, _ amplitude: Float) -> [Float] {
    (0..<Int(seconds * 16_000)).map { amplitude * sinf(2 * .pi * 220 * Float($0) / 16_000) }
}
func checkRoom(_ seconds: Double, _ amplitude: Float = 0.001) -> [Float] {
    var rng = SystemRandomNumberGenerator()
    return (0..<Int(seconds * 16_000)).map { _ in amplitude * Float.random(in: -1...1, using: &rng) }
}

let clockSeg = VoicePromptSegmenter(gap: 5)
var clockCommits: [String] = []
clockSeg.onCommit = { clockCommits.append($0) }
clockSeg.start()
clockSeg.feedAudio(checkRoom(1.0), sampleRate: 16_000)
clockSeg.handle("hello world", isFinal: false)
clockSeg.feedAudio(checkTone(0.3, 0.05) + checkRoom(0.35), sampleRate: 16_000)
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
check(clockCommits == ["hello world"], "quiet clock commits before the text gap")

// A final for that same utterance right after must not make a second turn.
clockSeg.handle("Hello world.", isFinal: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
check(clockCommits == ["hello world"], "late final for the clock's utterance is dropped")

// A genuinely new utterance still commits.
clockSeg.handle("second", isFinal: true)
check(clockCommits == ["hello world", "second"], "a different final still commits")
clockSeg.stop()

print("ALL OK")
