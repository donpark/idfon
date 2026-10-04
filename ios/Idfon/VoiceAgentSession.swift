import AVFAudio
import Foundation

/// A1 client-side voice agent loop: on-device STT -> text turn to the agent
/// peer -> await the reply -> on-device TTS. This is the cascade the holder
/// side-channel replaces GPT-Live with; the app owns all audio.
///
/// One long-lived analyzer stays prepared for the whole session; the mic tap is
/// paused while the agent thinks/speaks so its own TTS can't leak into the next
/// prompt. `VoicePromptSegmenter` picks utterance boundaries: a final result
/// commits immediately, a 1.2 s no-change gap is the fallback. iOS 26+ uses the
/// SpeechAnalyzer; older iOS falls back to a per-turn SFSpeechRecognizer.
///
/// UI drives `start`/`stop`; `run`/`runText` are launch-arg automations.
@MainActor
final class VoiceAgentSession: NSObject {
    static let shared = VoiceAgentSession()

    enum State: Equatable {
        case idle
        case listening(String)
        case thinking
        case speaking(String)
    }

    private let voice = OnDeviceVoice.shared
    private let synthesizer = AVSpeechSynthesizer()
    private var speechDelegate: SpeechDelegate?
    private let segmenter = VoicePromptSegmenter()
    private var analyzer: Any?

    private(set) var isActive = false
    var onState: ((State) -> Void)?

    private var stopRequested = false
    private var turnLimit = Int.max
    private var turnsDone = 0
    private var client = DaemonClient()
    private var promptWaiter: CheckedContinuation<String?, Never>?

    /// Continuous conversation until `stop()`.
    func start(peerRef: String, turns: Int = Int.max) {
        guard !isActive else { return }
        isActive = true
        stopRequested = false
        turnLimit = turns
        turnsDone = 0
        configureSession()
        segmenter.onPartial = { [weak self] text in self?.onState?(.listening(text)) }
        segmenter.onCommit = { [weak self] text in self?.deliver(text) }
        segmenter.start()
        startAnalyzer()
        Task { @MainActor in
            let peers = (try? await client.peers()) ?? []
            guard let peer = peers.first(where: { $0.id == peerRef || $0.name == peerRef }) else {
                Automation.mark("voice-agent: FAIL no peer \(peerRef)")
                finish()
                return
            }
            Automation.mark("voice-agent: start peer=\(peer.id)")
            // Let ChatStore finish hydrating so the reply snapshot excludes
            // pre-existing history.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while !stopRequested && turnsDone < turnLimit {
                guard await performTurn(peerId: peer.id) else { break }
            }
            Automation.mark("voice-agent: done")
            finish()
        }
    }

    func stop() {
        stopRequested = true
        deliver(nil)
    }

    /// One-shot automation (`-voiceagent <ref> [turns]`).
    func run(peerRef: String, turns: Int) {
        start(peerRef: peerRef, turns: turns)
    }

    /// Text-driven verification (`-voiceagenttext <ref> <text>`).
    func runText(peerRef: String, text: String) {
        configureSession()
        Task { @MainActor in
            let peers = (try? await client.peers()) ?? []
            guard let peer = peers.first(where: { $0.id == peerRef || $0.name == peerRef }) else {
                Automation.mark("voice-agent-text: FAIL no peer \(peerRef)")
                return
            }
            Automation.mark("voice-agent-text: start peer=\(peer.id) text=\(text)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let reply = await sendAndAwait(peerId: peer.id, text: text, logPrefix: "voice-agent-text")
            else { return }
            Automation.mark("voice-agent-text: reply=\(reply)")
            if !reply.isEmpty { await speak(reply) }
            Automation.mark("voice-agent-text: done")
        }
    }

    // MARK: - turn

    private func performTurn(peerId: String) async -> Bool {
        turnsDone += 1
        onState?(.listening(""))
        guard let heard = await listenOnce(), !heard.isEmpty else {
            Automation.mark("voice-agent: FAIL turn=\(turnsDone) no transcript")
            return false
        }
        Automation.mark("voice-agent: heard=\(heard)")
        onState?(.thinking)
        guard let reply = await sendAndAwait(peerId: peerId, text: heard, logPrefix: "voice-agent")
        else { return false }
        Automation.mark("voice-agent: reply=\(reply)")
        if !reply.isEmpty {
            onState?(.speaking(reply))
            await speak(reply)
        }
        onState?(.idle)
        return turnsDone < turnLimit
    }

    private func sendAndAwait(peerId: String, text: String, logPrefix: String) async -> String? {
        let before = Set(ChatStore.shared.messages(for: peerId).map(\.id))
        do {
            try await client.sendText(to: peerId, text)
        } catch {
            Automation.mark("\(logPrefix): FAIL send \(error.localizedDescription)")
            return nil
        }
        guard let reply = await waitForReply(peerId: peerId, excluding: before) else {
            Automation.mark("\(logPrefix): FAIL no reply")
            return nil
        }
        return Self.stripEnvelopes(reply)
    }

    private func finish() {
        isActive = false
        stopRequested = true
        segmenter.stop()
        if #available(iOS 26.0, *), let transcriber = analyzer as? SystemSpeechTranscriber {
            transcriber.stop()
        }
        analyzer = nil
        deliver(nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        turnsDone = 0
        turnLimit = Int.max
        onState?(.idle)
    }

    // MARK: - analyzer lifecycle

    /// One session for the whole voice mode: the analyzer records while TTS
    /// plays back on the same play-and-record session, so `speak()` must not
    /// reconfigure it mid-session.
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startAnalyzer() {
        guard #available(iOS 26.0, *) else { return }
        let transcriber = SystemSpeechTranscriber()
        analyzer = transcriber
        Task { [weak self] in
            do {
                try await transcriber.start(
                    // No AEC: the mic is paused whenever the agent speaks.
                    enableVoiceProcessing: false,
                    onText: { [weak self] text, isFinal in
                        DispatchQueue.main.async { self?.segmenter.handle(text, isFinal: isFinal) }
                    },
                    onError: { [weak self] message in
                        Automation.mark("voice-agent: analyzer error \(message)")
                        DispatchQueue.main.async { self?.restartAnalyzer() }
                    }
                )
            } catch {
                Automation.mark("voice-agent: analyzer start failed \(error.localizedDescription)")
            }
        }
    }

    /// LiveSub's lesson: a failed recognizer stays dead until reset. Rebuild it.
    private func restartAnalyzer() {
        guard isActive, #available(iOS 26.0, *) else { return }
        (analyzer as? SystemSpeechTranscriber)?.stop()
        analyzer = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.isActive else { return }
            self.startAnalyzer()
        }
    }

    // MARK: - prompt handoff

    private func deliver(_ text: String?) {
        guard let waiter = promptWaiter else { return }
        promptWaiter = nil
        waiter.resume(returning: text)
    }

    private func awaitPrompt() async -> String? {
        if stopRequested { return nil }
        return await withCheckedContinuation { continuation in
            if stopRequested { continuation.resume(returning: nil); return }
            promptWaiter = continuation
        }
    }

    // MARK: - speech

    private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
        let finish: () -> Void
        init(finish: @escaping () -> Void) { self.finish = finish }
        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer,
            didFinish utterance: AVSpeechUtterance
        ) {
            finish()
        }
    }

    /// One user turn. On iOS 26+ the analyzer is already running; the mic is
    /// resumed for the turn and paused again while the agent responds.
    private func listenOnce(timeout: TimeInterval = 30) async -> String? {
        if #available(iOS 26.0, *), let transcriber = analyzer as? SystemSpeechTranscriber {
            segmenter.setEnabled(true)
            segmenter.clear()
            transcriber.resume()
            let heard = await awaitPromptWithTimeout(timeout)
            segmenter.setEnabled(false)
            transcriber.pause()
            return heard
        }
        return await listenWithSFSpeech(timeout: timeout)
    }

    private func awaitPromptWithTimeout(_ timeout: TimeInterval) async -> String? {
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.deliver(nil)
        }
        let heard = await awaitPrompt()
        deadline.cancel()
        return heard
    }

    /// Older iOS: one SFSpeech listening phase per turn.
    private func listenWithSFSpeech(timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            var latest = ""
            var lastChange = Date()
            let started = Date()
            var resumed = false
            var timer: Timer?
            let finish: (String?) -> Void = { text in
                guard !resumed else { return }
                resumed = true
                timer?.invalidate()
                self.voice.stopListening()
                continuation.resume(returning: text)
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                if self.stopRequested {
                    finish(latest.isEmpty ? nil : latest)
                } else if !latest.isEmpty, Date().timeIntervalSince(lastChange) > 1.2 {
                    finish(latest)
                } else if Date().timeIntervalSince(started) > timeout {
                    finish(latest.isEmpty ? nil : latest)
                }
            }
            self.voice.startListening(
                configureSession: false,
                enableVoiceProcessing: false,
                onPartial: { text in
                    latest = text
                    lastChange = Date()
                    self.onState?(.listening(text))
                }
            ) { result in
                timer?.invalidate()
                switch result {
                case .success(let text): finish(text)
                case .failure: finish(latest.isEmpty ? nil : latest)
                }
            }
        }
    }

    private func waitForReply(peerId: String, excluding: Set<String>) async -> String? {
        for _ in 0..<60 {
            if stopRequested { return nil }
            let messages = ChatStore.shared.messages(for: peerId)
            for message in messages.reversed()
            where !message.outgoing && !excluding.contains(message.id) {
                if case .text(let text) = message.kind {
                    return text
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    private func speak(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = SpeechVoice.best(language: "en-US")
            let delegate = SpeechDelegate { continuation.resume() }
            speechDelegate = delegate
            synthesizer.delegate = delegate
            synthesizer.speak(utterance)
        }
    }

    /// Drop `IDFON-*/1` envelope blocks so only the spoken text is read aloud.
    static func stripEnvelopes(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("IDFON-") && line.hasSuffix("/1") { break }
            lines.append(String(line))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
