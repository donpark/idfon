import AVFAudio
import Foundation
import Speech

/// A1 client-side voice agent loop (macOS): on-device STT -> text turn to the
/// agent peer -> await the reply -> on-device TTS. Mirror of the iOS
/// `VoiceAgentSession`; the macOS app owns all audio.
///
/// One long-lived analyzer stays prepared for the whole session; the mic tap is
/// paused while the agent thinks/speaks so its own TTS can't leak into the next
/// prompt. `VoicePromptSegmenter` picks utterance boundaries: a final result
/// commits immediately, a 1.2 s no-change gap is the fallback. macOS 26+ uses
/// the SpeechAnalyzer; older macOS falls back to a per-turn SFSpeechRecognizer.
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

    // Timer's @Sendable closure can't see MainActor isolation; this flag is only
    // ever read/written on the main thread (stop() is MainActor, timers run on main).
    nonisolated(unsafe) private var stopRequested = false
    private var turnLimit = Int.max
    private var turnsDone = 0
    /// Consecutive silent turns; a call is only dropped after several.
    private var noSpeechTurns = 0
    private var client = DaemonClient()
    private var promptWaiter: CheckedContinuation<String?, Never>?
    /// Last text spoken by TTS, so the agent's own tail can be dropped instead
    /// of re-sent as a user turn (self-bleed).
    private var lastSpoken: String?

    func start(peerRef: String, turns: Int = Int.max) {
        guard !isActive else { return }
        isActive = true
        stopRequested = false
        turnLimit = turns
        turnsDone = 0
        segmenter.onPartial = { [weak self] text in self?.onState?(.listening(text)) }
        segmenter.onCommit = { [weak self] text in self?.deliver(text) }
        segmenter.start()
        Task { @MainActor in
            let peers = (try? await client.peers()) ?? []
            guard let peer = peers.first(where: { $0.id == peerRef || $0.name == peerRef }) else {
                Automation.mark("voice-agent: FAIL no peer \(peerRef)")
                finish()
                return
            }
            Automation.mark("voice-agent: start peer=\(peer.id)")
            // Wait for the recognizer before the turn loop (first-run model).
            await startAnalyzer()
            // Let ChatStore finish hydrating so the reply snapshot excludes
            // pre-existing history.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Greet like a live call, fetched before the cue so "answered" is
            // followed immediately by speech instead of dead air.
            var greeting: String?
            if !stopRequested {
                greeting = await sendAndAwait(
                    peerId: peer.id,
                    text: "The caller just connected on a voice call. Greet them briefly and invite them to speak.",
                    logPrefix: "voice-agent-greet"
                )
            }
            CallTonePlayer.shared.start(.answered)
            if let greeting, !greeting.isEmpty, !stopRequested {
                onState?(.speaking(greeting))
                await speak(greeting)
            }
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

    func run(peerRef: String, turns: Int) {
        start(peerRef: peerRef, turns: turns)
    }

    func runText(peerRef: String, text: String) {
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
        var heard: String?
        // Retry within the turn when the recognizer catches the agent's own TTS
        // tail; only a transcript that is not the last spoken reply is sent.
        for _ in 0..<3 {
            onState?(.listening(""))
            guard let text = await listenOnce(), !text.isEmpty else { break }
            if let spoken = lastSpoken, !spoken.isEmpty,
               voice.isEcho(spoken: spoken, heard: text) {
                Automation.mark("voice-agent: dropped echo heard=\(text)")
                continue
            }
            // Optional on-device LM cleanup (fail-open to the raw transcript).
            let corrected = await SpeechCorrection.correct(text)
            if corrected != text {
                Automation.mark("voice-agent: corrected=\(corrected)")
            }
            heard = corrected
            break
        }
        guard let heard, !heard.isEmpty else {
            noSpeechTurns += 1
            Automation.mark("voice-agent: no transcript turn=\(turnsDone) streak=\(noSpeechTurns)")
            // One silent turn is not a hangup; only give up after a few.
            return noSpeechTurns < 3
        }
        noSpeechTurns = 0
        Automation.mark("voice-agent: heard=\(heard)")
        onState?(.thinking)
        guard let reply = await sendAndAwait(peerId: peerId, text: heard, logPrefix: "voice-agent")
        else {
            // A missing reply must not kill the call; try the next turn.
            Automation.mark("voice-agent: no reply, continuing")
            return true
        }
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
        guard isActive else { return }
        isActive = false
        stopRequested = true
        segmenter.stop()
        if #available(macOS 26.0, *), let transcriber = analyzer as? MacSpeechTranscriber {
            transcriber.stop()
        }
        analyzer = nil
        deliver(nil)
        turnsDone = 0
        turnLimit = Int.max
        noSpeechTurns = 0
        onState?(.idle)
        // Play the end cue, then release the tone engine once it has played out.
        CallTonePlayer.shared.start(.ended)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !self.isActive else { return }
            CallTonePlayer.shared.stop()
        }
    }

    // MARK: - analyzer lifecycle

    private func startAnalyzer() async {
        guard #available(macOS 26.0, *) else { return }
        let transcriber = MacSpeechTranscriber()
        analyzer = transcriber
        do {
            try await transcriber.start(
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

    /// LiveSub's lesson: a failed recognizer stays dead until reset. Rebuild it.
    private func restartAnalyzer() {
        guard isActive, #available(macOS 26.0, *) else { return }
        (analyzer as? MacSpeechTranscriber)?.stop()
        analyzer = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.isActive else { return }
            await self.startAnalyzer()
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

    /// One user turn. On macOS 26+ the analyzer is already running; the mic is
    /// resumed for the turn and paused again while the agent responds.
    private func listenOnce(timeout: TimeInterval = 30) async -> String? {
        if #available(macOS 26.0, *), let transcriber = analyzer as? MacSpeechTranscriber {
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

    /// Older macOS: one SFSpeech listening phase per turn.
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
            // VoiceOver's selected voice/rate must not override ours.
            utterance.prefersAssistiveTechnologySettings = false
            let delegate = SpeechDelegate { continuation.resume() }
            speechDelegate = delegate
            synthesizer.delegate = delegate
            synthesizer.speak(utterance)
        }
        lastSpoken = text
        // The tap gate is still closed here; hold it closed briefly so the
        // speaker/acoustic tail decays before the next turn re-arms the mic.
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    static func stripEnvelopes(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("IDFON-") && line.hasSuffix("/1") { break }
            lines.append(String(line))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
