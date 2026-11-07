import Foundation

/// Bubble replay P0 (#202): tap a spoken bubble to hear its text re-synthesized
/// in the contact's on-device voice; tap again to stop. One replay at a time,
/// on a fresh engine so the call engine (`SpeechEngines.tts`) is untouched, and
/// with no call sink so it plays locally — on-device voices need no network.
/// Threading: this class holds only the state; model load and synthesis run in
/// a background task and hop back only to publish state.
///
/// Exact-audio replay (cached turn PCM), the caller's own audio, and cloned
/// voices are P1–P3 and deliberately absent — see `BubbleTap` for the tap
/// decisions those phases will extend.
@MainActor
final class BubbleReplay {
    static let shared = BubbleReplay()

    /// The message id being read; rows read this for their reading state.
    private(set) var readingID: String?
    /// Fires on the main thread when a replay starts or ends (one chat at a
    /// time: leaving the chat stops the replay first).
    var onChange: (() -> Void)?

    private var engine: TtsEngine?

    private init() {}

    /// Handle a bubble tap: decide, act, and return the action so the caller
    /// can surface a notice. Main-thread work here is O(1).
    func tap(messageID: String, role: String, text: String, final: Bool,
             peerID: String, callActive: Bool) -> BubbleTap.Action {
        let action = BubbleTap.action(role: role, text: text, final: final,
                                      callActive: callActive, reading: readingID == messageID)
        switch action {
        case .play:
            play(messageID: messageID, text: text, peerID: peerID)
        case .stop:
            stop()
        case .notice:
            break
        }
        return action
    }

    func isReading(_ messageID: String) -> Bool { readingID == messageID }

    private func play(messageID: String, text: String, peerID: String) {
        stop()
        let pick = ContactOnDeviceEngines.tts(for: peerID).flatMap(TtsBackend.init(rawValue:))
        let engine = SpeechEngines.makeTts(pick ?? SpeechEngines.backend)
        self.engine = engine
        readingID = messageID
        onChange?()
        Task.detached(priority: .userInitiated) { [weak self] in
            await engine.prepare()
            await engine.speak(text)
            await self?.finished(engine)
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        guard readingID != nil else { return }
        readingID = nil
        onChange?()
    }

    /// Natural end (or `stop()`, which resumes `speak()`): clear state only if
    /// this engine is still the one playing, so an already-cleared stop cannot
    /// touch a newer replay.
    private func finished(_ engine: TtsEngine) {
        guard self.engine === engine else { return }
        self.engine = nil
        readingID = nil
        onChange?()
    }
}
