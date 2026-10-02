import AVFAudio
import Foundation

/// A1 client-side voice agent loop: on-device STT -> text turn to the agent
/// peer -> await the reply -> on-device TTS. This is the cascade the holder
/// side-channel replaces GPT-Live with; the app owns all audio.
///
/// Driven by `-voiceagent <peer-ref> [turns]` for now (real UI later).
@MainActor
final class VoiceAgentSession: NSObject {
    static let shared = VoiceAgentSession()

    private let voice = OnDeviceVoice.shared
    private let synthesizer = AVSpeechSynthesizer()
    private var speechDelegate: SpeechDelegate?

    /// One final utterance from the microphone.
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

    func run(peerRef: String, turns: Int) {
        Task { @MainActor in
            let client = DaemonClient()
            let peers = (try? await client.peers()) ?? []
            guard let peer = peers.first(where: { $0.id == peerRef || $0.name == peerRef }) else {
                Automation.mark("voice-agent: FAIL no peer \(peerRef)")
                return
            }
            Automation.mark("voice-agent: start peer=\(peer.id) turns=\(turns)")
            // Let ChatStore finish hydrating so the reply snapshot excludes
            // pre-existing history.
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            for turn in 1...max(1, turns) {
                guard let heard = await listenOnce(), !heard.isEmpty else {
                    Automation.mark("voice-agent: FAIL turn=\(turn) no transcript")
                    break
                }
                Automation.mark("voice-agent: heard=\(heard)")

                let before = Set(ChatStore.shared.messages(for: peer.id).map(\.id))
                do {
                    try await client.sendText(to: peer.id, heard)
                } catch {
                    Automation.mark("voice-agent: FAIL turn=\(turn) send \(error.localizedDescription)")
                    break
                }
                guard let reply = await waitForReply(peerId: peer.id, excluding: before) else {
                    Automation.mark("voice-agent: FAIL turn=\(turn) no reply")
                    break
                }
                let spoken = Self.stripEnvelopes(reply)
                Automation.mark("voice-agent: reply=\(spoken)")
                if !spoken.isEmpty {
                    await speak(spoken)
                }
            }
            Automation.mark("voice-agent: done")
        }
    }

    /// One user turn: prefer the recognizer's final, but accept the latest
    /// partial once speech has settled (final only arrives at end-of-input).
    /// Text-driven variant for verifying send -> await reply -> speak without
    /// depending on a live utterance.
    func runText(peerRef: String, text: String) {
        Task { @MainActor in
            let client = DaemonClient()
            let peers = (try? await client.peers()) ?? []
            guard let peer = peers.first(where: { $0.id == peerRef || $0.name == peerRef }) else {
                Automation.mark("voice-agent-text: FAIL no peer \(peerRef)")
                return
            }
            Automation.mark("voice-agent-text: start peer=\(peer.id) text=\(text)")
            // Let ChatStore finish hydrating so the reply snapshot excludes
            // pre-existing history.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let before = Set(ChatStore.shared.messages(for: peer.id).map(\.id))
            Automation.mark("voice-agent-text: history=\(before.count)")
            do {
                try await client.sendText(to: peer.id, text)
            } catch {
                Automation.mark("voice-agent-text: FAIL send \(error.localizedDescription)")
                return
            }
            guard let reply = await waitForReply(peerId: peer.id, excluding: before) else {
                Automation.mark("voice-agent-text: FAIL no reply")
                return
            }
            let spoken = Self.stripEnvelopes(reply)
            Automation.mark("voice-agent-text: reply=\(spoken)")
            if !spoken.isEmpty { await speak(spoken) }
            Automation.mark("voice-agent-text: done")
        }
    }

    private func listenOnce(timeout: TimeInterval = 30) async -> String? {
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
                if !latest.isEmpty, Date().timeIntervalSince(lastChange) > 1.2 {
                    finish(latest)
                } else if Date().timeIntervalSince(started) > timeout {
                    finish(latest.isEmpty ? nil : latest)
                }
            }
            self.voice.startListening(
                configureSession: true,
                enableVoiceProcessing: false,
                onPartial: { text in
                latest = text
                lastChange = Date()
            }) { result in
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
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
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
