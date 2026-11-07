import AVFAudio
import Foundation

/// Bubble replay (#202): tap a spoken bubble to hear it again — the turn's
/// exact audio when one exists (P1/P2: captured during the call, or fetched
/// from the holder's `audio_ticket`), otherwise the text re-synthesized in the
/// contact's on-device voice (P0). Tap again to stop. One replay at a time, on
/// a fresh engine so the call engine (`SpeechEngines.tts`) is untouched, and
/// with no call sink so it plays locally — on-device voices need no network.
/// Threading: this class holds only the state; fetch, file writes and
/// synthesis run off-main and hop back only to publish state.
///
/// A cloned voice for turns without stored audio is P3 (explicit opt-in, local
/// only) and deliberately absent — see `BubbleTap` for the tap decisions.
@MainActor
final class BubbleReplay {
    static let shared = BubbleReplay()

    /// Which audio a tap asked for (the long-press/right-click menu).
    enum Mode {
        case auto   // exact when available, else re-synth
        case exact  // only the stored/captured audio
        case synth  // force re-synthesis
    }

    /// The message id being read; rows read this for their reading state.
    private(set) var readingID: String?
    /// Fires on the main thread when a replay starts or ends (one chat at a
    /// time: leaving the chat stops the replay first).
    var onChange: (() -> Void)?

    /// The replay voice (a Phonon voice name) — picked from the bubble menu,
    /// which is also the explicit opt-in for replaying the user's own turns
    /// in a cloned voice when no original audio is stored (#202 P3). nil =
    /// the contact's configured voice (caller turns then say "no stored
    /// audio" instead of substituting). Local only: the voice file plays on
    /// device; no audio is sent anywhere for replay.
    var voice: String? {
        get { UserDefaults.standard.string(forKey: "idfon.replay.voice") }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: "idfon.replay.voice")
            } else {
                UserDefaults.standard.removeObject(forKey: "idfon.replay.voice")
            }
        }
    }

    private var engine: TtsEngine?
    private var player: AVAudioPlayer?
    private let playerDone = ReplayPlayerDone()
    /// Bumped by `stop()` so an in-flight fetch cannot hijack a newer replay.
    private var playSeq = 0
    private lazy var client = DaemonClient()

    private init() {
        playerDone.onFinish = { [weak self] in self?.playerFinished() }
    }

    /// Whether the turn has exact audio to replay (captured or ticketed).
    func hasAudio(turnID: String, ticket: String?) -> Bool {
        ticket != nil || TurnReplayStore.url(for: turnID) != nil
    }

    /// Handle a bubble tap: decide, act, and return the action so the caller
    /// can surface a notice. Main-thread work here is O(1).
    func tap(messageID: String, role: String, text: String, final: Bool,
             peerID: String, callActive: Bool,
             turnID: String, ticket: String?, mode: Mode = .auto) -> BubbleTap.Action {
        let action = BubbleTap.action(role: role, text: text, final: final,
                                      callActive: callActive, reading: readingID == messageID,
                                      audioAvailable: hasAudio(turnID: turnID, ticket: ticket),
                                      cloneVoiceAvailable: voice != nil)
        switch action {
        case .play:
            play(messageID: messageID, role: role, text: text, peerID: peerID,
                 turnID: turnID, ticket: ticket, mode: mode)
        case .stop:
            // A menu pick on the reading bubble is a mode switch, not a
            // toggle: replay it the chosen way.
            guard mode == .auto else {
                play(messageID: messageID, role: role, text: text, peerID: peerID,
                     turnID: turnID, ticket: ticket, mode: mode)
                return .play
            }
            stop()
        case .notice:
            break
        }
        return action
    }

    func isReading(_ messageID: String) -> Bool { readingID == messageID }

    func stop() {
        playSeq += 1
        player?.stop()
        player = nil
        engine?.stop()
        engine = nil
        clearReading()
    }

    // MARK: - exact audio

    private func play(messageID: String, role: String, text: String, peerID: String,
                      turnID: String, ticket: String?, mode: Mode) {
        stop()
        if mode != .synth {
            if let url = TurnReplayStore.url(for: turnID),
               let file = try? AVAudioPlayer(contentsOf: url) {
                startPlayer(messageID: messageID, player: file)
                return
            }
            if let ticket {
                playTicket(messageID: messageID, turnID: turnID, ticket: ticket,
                           text: text, peerID: peerID, role: role, mode: mode)
                return
            }
        }
        if mode == .exact {
            CallFeedback.post("No stored audio for this turn")
            return
        }
        // #202 P3: a caller turn with no original plays in the configured
        // replay voice (the user's clone) — and says so, never silently.
        if role != "agent" {
            guard voice != nil else {
                CallFeedback.post("No stored audio for this turn")
                return
            }
            CallFeedback.post("Cloned voice — not the original audio")
        }
        playSynth(messageID: messageID, text: text, peerID: peerID)
    }

    /// The holder's ticketed audio: fetch, cache locally, play. A failed fetch
    /// re-synthesizes agent turns and says so on caller turns (never a silent
    /// substitution).
    private func playTicket(messageID: String, turnID: String, ticket: String,
                            text: String, peerID: String, role: String, mode: Mode) {
        readingID = messageID // the fetch reads as "Reading…" until it lands
        onChange?()
        let seq = playSeq
        Task { [weak self] in
            guard let self else { return }
            let data = try? await self.client.fetchBlob(ticket)
            guard self.playSeq == seq else { return }
            if let data {
                // Cache fill is best effort; playback uses the bytes in hand.
                Task.detached(priority: .utility) {
                    _ = TurnReplayStore.store(turnKey: turnID, wav: data)
                }
                if let file = try? AVAudioPlayer(data: data) {
                    self.startPlayer(messageID: messageID, player: file)
                    return
                }
            }
            Automation.mark("turn-replay: ticket audio failed key=\(turnID)")
            if role == "agent", mode != .exact {
                self.playSynth(messageID: messageID, text: text, peerID: peerID)
            } else {
                self.clearReading()
                CallFeedback.post("Stored audio could not be loaded")
            }
        }
    }

    private func startPlayer(messageID: String, player: AVAudioPlayer) {
        player.delegate = playerDone
        self.player = player
        readingID = messageID
        onChange?()
        if !player.play() {
            self.player = nil
            clearReading()
            CallFeedback.post("Stored audio could not be played")
        }
    }

    private func playerFinished() {
        guard player != nil else { return }
        player = nil
        clearReading()
    }

    // MARK: - re-synthesis (P0)

    private func playSynth(messageID: String, text: String, peerID: String) {
        let pick = ContactOnDeviceEngines.tts(for: peerID).flatMap(TtsBackend.init(rawValue:))
        let engine = SpeechEngines.makeTts(pick ?? SpeechEngines.ttsBackend)
        engine.voice = voice
        self.engine = engine
        readingID = messageID
        onChange?()
        Task.detached(priority: .userInitiated) { [weak self] in
            await engine.prepare()
            await engine.speak(text)
            await self?.finished(engine)
        }
    }

    private func clearReading() {
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
        clearReading()
    }
}

/// Completion for file replay, delivered where `play()` was called (main).
/// Mirrors `SpeechCompletion`'s exactly-once shape.
private final class ReplayPlayerDone: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?()
    }
}
