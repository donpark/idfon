import Foundation

/// Accumulates recognizer results into committed prompts for the A1 voice loop.
///
/// - volatile partials update the live display only;
/// - a final result commits immediately (the transcriber's segment reset);
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

    var onPartial: ((String) -> Void)?
    var onCommit: ((String) -> Void)?

    init(gap: TimeInterval = 1.2) { self.gap = gap }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setEnabled(_ value: Bool) { enabled = value }

    func clear() {
        latest = ""
        lastChange = Date()
    }

    func handle(_ text: String, isFinal: Bool) {
        guard enabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        latest = trimmed
        lastChange = Date()
        onPartial?(trimmed)
        if isFinal { commit(trimmed) }
    }

    private func tick() {
        guard enabled, !latest.isEmpty, Date().timeIntervalSince(lastChange) > gap else { return }
        commit(latest)
    }

    private func commit(_ text: String) {
        guard text != lastCommitted else { return }
        lastCommitted = text
        latest = ""
        onCommit?(text)
    }
}
