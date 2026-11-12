import Foundation

/// Accumulates recognizer results into committed prompts for the A1 voice loop.
///
/// - volatile partials update the live display only;
/// - a final result commits immediately (the transcriber's segment reset);
/// - if enabled (`IDFON_QUIET_END=1`) and the mic stays quiet for 240 ms (the
///   learned room floor, not a fixed level), the latest text commits once it
///   has settled for 150 ms;
/// - if partials stop changing for `gap` seconds the latest text commits as a
///   fallback;
/// - committed text is remembered so a late final for the same segment is not
///   sent twice.
///
/// Not thread-safe: drive it from the main thread/run loop only.
final class VoicePromptSegmenter {
    private let gap: TimeInterval
    private var latest = ""
    private var lastChange = Date()
    private var lastCommitted = ""
    private var enabled = true
    private var timer: Timer?

    /// Benchmarking (docs/benchmarks.md): ms between the recognizer's last
    /// update and the commit — the turn-detection heuristic's cost (0 on a
    /// recognizer final, `gap` + tick latency on the silence fallback).
    private(set) var lastCommitGapMs = 0
    private(set) var lastCommitFinal = false

    var onPartial: ((String) -> Void)?
    var onCommit: ((String) -> Void)?

    /// RealtimeVAD's early end (SPEC.md): commit after 240 ms of measured
    /// quiet, once the recognizer's text has settled for 150 ms. OFF by
    /// default: on the endpoint audit's real call clips a 240 ms run fires in
    /// 8/20 turns that do not end there (docs/benchmarks.md), so the text-gap
    /// fallback stays the end until a caller-channel call validates it.
    /// `IDFON_QUIET_END=1` enables it for that test.
    static let earlyEndS: TimeInterval = {
        ProcessInfo.processInfo.environment["IDFON_QUIET_END"] == "1" ? 0.24 : 0
    }()
    private static let textSettledS: TimeInterval = 0.15

    /// Quiet clock: 10 ms noise-referenced quiet, fed the same mic audio the
    /// recognizer hears, so a pause is measured in audio time rather than in
    /// recognizer-text time. Every commit logs what it saw.
    private let clock = QuietClock()
    private var clockPauses = 0
    private var clockLongResumed = 0
    private var clockMaxResumed: TimeInterval = 0
    /// Text the clock already committed, for suppressing its late final.
    private var lastEarlyCommit: (text: String, at: Date)?

    init(gap: TimeInterval = 1.2) {
        self.gap = gap
        clock.onPause = { [weak self] _ in self?.clockPauses += 1 }
        clock.onResume = { [weak self] quiet, _ in
            guard let self else { return }
            clockMaxResumed = max(clockMaxResumed, quiet)
            if quiet >= Self.earlyEndS { clockLongResumed += 1 }
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { dropClock() }
    }

    func clear() {
        latest = ""
        lastChange = Date()
        dropClock()
    }

    /// The mic audio behind the current segment (main thread; skip while the
    /// mic is gated for TTS). Drives the quiet clock's early end.
    func feedAudio(_ samples: [Float], sampleRate: Double) {
        guard enabled else { return }
        clock.feed(samples, sampleRate: sampleRate)
    }

    private func dropClock() {
        clock.end()
        clockPauses = 0
        clockLongResumed = 0
        clockMaxResumed = 0
    }

    func handle(_ text: String, isFinal: Bool) {
        guard enabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if latest.isEmpty { clock.begin() }
        latest = trimmed
        lastChange = Date()
        onPartial?(trimmed)
        if isFinal {
            // A final that lands just after the clock committed the same
            // utterance only confirms what the agent already received; sending
            // it again would make a second turn. shortcut: the confirmation's
            // extra words are dropped, revisit if recognizers start finalizing
            // materially later than 1 s.
            if let early = lastEarlyCommit, Date().timeIntervalSince(early.at) < 1.0,
               Self.sameUtterance(early.text, trimmed) {
                lastEarlyCommit = nil
                latest = ""
                return
            }
            commit(trimmed, viaFinal: true, via: "final")
        }
    }

    /// Same utterance across a partial/final revision (case and punctuation
    /// change; the words do not).
    private static func sameUtterance(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        let n = min(8, min(x.count, y.count))
        return n > 0 && x.prefix(n) == y.prefix(n)
    }

    private func tick() {
        guard enabled, !latest.isEmpty else { return }
        let age = Date().timeIntervalSince(lastChange)
        if Self.earlyEndS > 0, clock.quietSeconds >= Self.earlyEndS, age >= Self.textSettledS {
            commit(latest, viaFinal: false, via: "clock")
            return
        }
        guard age > gap else { return }
        commit(latest, viaFinal: false, via: "gap")
    }

    /// The turn model's ENDPOINT (the tyger option): commit the current text
    /// now. The classic signals stay live as the fail-open net.
    func forceCommit() {
        guard enabled, !latest.isEmpty else { return }
        commit(latest, viaFinal: false, via: "force")
    }

    private func commit(_ text: String, viaFinal: Bool, via: String) {
        lastCommitGapMs = Int(Date().timeIntervalSince(lastChange) * 1000)
        lastCommitFinal = viaFinal
        guard text != lastCommitted else { return }
        // Recognizers occasionally emit punctuation-only fragments (""); never
        // pass those through as a user turn.
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else {
            latest = ""
            return
        }
        lastCommitted = text
        latest = ""
        if via == "clock" { lastEarlyCommit = (text, Date()) }
        let quietMs = Int(clock.quietSeconds * 1000)
        Automation.mark(
            "quiet-clock: via=\(via) pauses=\(clockPauses) long_resumed=\(clockLongResumed) "
                + "max_resumed_ms=\(Int(clockMaxResumed * 1000)) end_quiet_ms=\(quietMs) "
                + "commit_gap_ms=\(lastCommitGapMs)"
        )
        dropClock()
        onCommit?(text)
    }
}
