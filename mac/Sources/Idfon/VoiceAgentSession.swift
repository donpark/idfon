import AVFAudio
import Foundation
import Speech

/// A1 client-side voice agent loop (macOS): on-device STT -> text turn to the
/// agent peer -> await the reply -> on-device TTS. Mirror of the iOS
/// `VoiceAgentSession`; the macOS app owns all audio.
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
    private var macTranscriber: Any?

    private(set) var isActive = false
    var onState: ((State) -> Void)?

    private var stopRequested = false
    private var turnLimit = Int.max
    private var turnsDone = 0
    private var client = DaemonClient()

    func start(peerRef: String, turns: Int = Int.max) {
        guard !isActive else { return }
        isActive = true
        stopRequested = false
        turnLimit = turns
        turnsDone = 0
        Task { @MainActor in
            let peers = (try? await client.peers()) ?? []
            guard let peer = peers.first(where: { $0.id == peerRef || $0.name == peerRef }) else {
                Automation.mark("voice-agent: FAIL no peer \(peerRef)")
                finish()
                return
            }
            Automation.mark("voice-agent: start peer=\(peer.id)")
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
        turnsDone = 0
        turnLimit = Int.max
        onState?(.idle)
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

    private func listenOnce(timeout: TimeInterval = 30) async -> String? {
        if #available(macOS 26.0, *) {
            return await listenWithAnalyzer(timeout: timeout)
        }
        return await listenWithSFSpeech(timeout: timeout)
    }

    @available(macOS 26.0, *)
    private func listenWithAnalyzer(timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let transcriber = MacSpeechTranscriber()
            macTranscriber = transcriber
            var latest = ""
            var lastChange = Date()
            let started = Date()
            var resumed = false
            var timer: Timer?
            let finish: (String?) -> Void = { text in
                guard !resumed else { return }
                resumed = true
                timer?.invalidate()
                transcriber.stop()
                self.macTranscriber = nil
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
            Task {
                do {
                    try await transcriber.start(
                        onText: { text, isFinal in
                            latest = text
                            lastChange = Date()
                            self.onState?(.listening(text))
                            if isFinal { finish(text) }
                        },
                        onError: { _ in finish(latest.isEmpty ? nil : latest) }
                    )
                } catch {
                    finish(nil)
                }
            }
        }
    }

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
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            let delegate = SpeechDelegate { continuation.resume() }
            speechDelegate = delegate
            synthesizer.delegate = delegate
            synthesizer.speak(utterance)
        }
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
