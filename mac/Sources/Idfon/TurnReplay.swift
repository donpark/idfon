import AVFAudio
import Foundation

/// Per-turn capture of what the caller heard and said (#202 P1/P2), on the
/// shared mic stream (`AudioMeter`) and the playback fan-in (`PlaybackBus`) —
/// the mac mirror of ios/Idfon/TurnReplay.swift:
/// - agent turns: the playback stream between `openAgent`/`closeAgent` — the
///   exact audio of the speak window, barge-trimmed like the bubble text.
/// - caller turns: the mic utterance the silence splitter closed just before
///   `commitCaller` — the original recording of that turn.
/// Capture arrives on the audio thread and appends in place (arrays, like
/// `TurnCapture`); file writes happen off-main at close. Nothing here blocks
/// the audio callback beyond array copies and a lock.
final class TurnReplayTap: AudioCaptureObserver, AudioPlaybackObserver {
    /// Speech level near the relay endpointer's ~0.009, padded by room noise.
    private static let speechLevel: Float = 0.02

    private let lock = NSLock()
    private var active = false
    private var callArmed = false
    /// The open agent window; nil outside a speak window.
    private var agent: TurnReplayChunk?
    /// Rolling mic utterance (the silence splitter's current segment).
    private var mic = TurnReplayChunk(key: "mic", capSamples: TurnReplayChunk.cap(60))
    private var micQuiet = 0
    private var micSpeech = false
    /// The utterance the splitter closed most recently (consumed by a commit).
    private var micClosed: (chunk: TurnReplayChunk, at: Date)?

    // MARK: - lifecycle (main-actor callers)

    func openAgent(key: String) {
        lock.lock()
        // Idempotent per key: a streamed unit reopens its own window per
        // chunk; a different key replaces (chunks run serialized on one chain).
        if agent?.key != key {
            agent = TurnReplayChunk(key: key, capSamples: TurnReplayChunk.cap(300))
        }
        lock.unlock()
        sync()
    }

    /// The closed agent window, only when `key` owns it (a stale close must
    /// not kill a newer window).
    func closeAgent(key: String) -> TurnReplayChunk? {
        lock.lock()
        let chunk = agent?.key == key ? agent : nil
        if chunk != nil { agent = nil }
        lock.unlock()
        sync()
        return chunk
    }

    func armCall() {
        lock.lock()
        callArmed = true
        lock.unlock()
        sync()
    }

    func disarmCall() {
        lock.lock()
        callArmed = false
        lock.unlock()
        sync()
    }

    /// The mic utterance for a caller turn: the just-closed one when it is
    /// fresh, else the open segment when it already holds speech.
    func commitMic() -> TurnReplayChunk? {
        lock.lock()
        defer { lock.unlock() }
        let chunk: TurnReplayChunk?
        if let closed = micClosed, Date().timeIntervalSince(closed.at) < 15 {
            chunk = closed.chunk
        } else if micSpeech, !mic.samples.isEmpty {
            chunk = mic
        } else {
            chunk = nil
        }
        resetMic()
        return chunk
    }

    /// A half-open utterance with no turn to bind to (echo/silence retries):
    /// drop it so it cannot leak into a later turn's replay.
    func clearMic() {
        lock.lock()
        resetMic()
        lock.unlock()
    }

    private func resetMic() {
        micClosed = nil
        mic = TurnReplayChunk(key: "mic", capSamples: TurnReplayChunk.cap(60))
        micQuiet = 0
        micSpeech = false
    }

    private func sync() {
        lock.lock()
        let should = callArmed || agent != nil
        let changed = should != active
        if changed { active = should }
        lock.unlock()
        guard changed else { return }
        if should {
            AudioMeter.addCaptureObserver(self)
            PlaybackBus.add(self)
        } else {
            AudioMeter.removeCaptureObserver(self)
            PlaybackBus.remove(self)
        }
    }

    // MARK: - audio-thread feed

    /// The mic stream: split into utterances on 0.8 s of silence (the relay's
    /// quiet tail is also 0.8 s).
    func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        micFeed(samples, rate: buffer.format.sampleRate)
    }

    /// The playback fan-in: everything the caller heard inside the window.
    func audioPlayback(samples: [Float], rate: Double) {
        lock.lock()
        agent?.append(samples, rate: rate)
        lock.unlock()
    }

    private func micFeed(_ samples: [Float], rate: Double) {
        let quietTail = max(1, Int(0.8 * rate))
        lock.lock()
        defer { lock.unlock() }
        guard callArmed else { return }
        var start = 0
        for i in samples.indices {
            if abs(samples[i]) > Self.speechLevel {
                micQuiet = 0
                micSpeech = true
            } else {
                micQuiet += 1
                if micSpeech, micQuiet >= quietTail {
                    // Close at the silence onset; the tail itself starts the
                    // next utterance (trimmed away at store time). The closed
                    // utterance must survive — only the rolling state resets.
                    let end = max(start, i - quietTail + 1)
                    mic.append(Array(samples[start..<end]), rate: rate)
                    micClosed = (mic, Date())
                    mic = TurnReplayChunk(key: "mic", capSamples: TurnReplayChunk.cap(60))
                    micQuiet = 0
                    micSpeech = false
                    start = end
                }
            }
        }
        if start < samples.count {
            mic.append(Array(samples[start..<samples.count]), rate: rate)
        }
    }
}

/// Accumulated PCM for one turn (audio-thread appends, read at close).
final class TurnReplayChunk {
    let key: String
    private(set) var samples: [Float] = []
    private(set) var rate: Double = 0
    private let cap: Int
    private var overflowed = false

    init(key: String, capSamples: Int) {
        self.key = key
        self.cap = capSamples
    }

    /// `seconds` of 48 kHz mono as a sample cap.
    static func cap(_ seconds: Int) -> Int { seconds * 48_000 }

    func append(_ more: [Float], rate: Double) {
        if self.rate == 0 { self.rate = rate }
        guard !overflowed, samples.count <= cap else {
            overflowed = true // keep the head; a runaway turn cannot grow forever
            return
        }
        samples.append(contentsOf: more)
    }
}

/// The replay capture's main-actor face: window/commit calls from the call
/// loops, file writes off-main.
@MainActor
final class TurnReplay {
    static let shared = TurnReplay()
    private let tap = TurnReplayTap()

    private init() {}

    /// Arm the mic utterance splitter for a call (client-cascade turns).
    func armCall() { tap.armCall() }

    func disarmCall() {
        tap.disarmCall()
        tap.clearMic()
    }

    /// Bind the mic utterance that just ended to this caller turn.
    func commitCaller(turnKey: String) {
        guard let chunk = tap.commitMic() else {
            Automation.mark("turn-replay: no mic utterance for \(turnKey)")
            return
        }
        store(chunk, turnKey: turnKey)
    }

    /// Window the agent's speak: what plays between open and close is the
    /// turn's exact audio. Idempotent per key (streamed chunks reopen once).
    func openAgent(turnKey: String) {
        tap.openAgent(key: turnKey)
    }

    func closeAgent(turnKey: String) {
        guard let chunk = tap.closeAgent(key: turnKey) else { return }
        store(chunk, turnKey: turnKey)
    }

    /// Drop a turn's captured audio (echo/backchannel turns keep no bubble).
    func discard(turnKey: String) {
        TurnReplayStore.discard(turnKey: turnKey)
        tap.clearMic()
    }

    private func store(_ chunk: TurnReplayChunk, turnKey: String) {
        let samples = chunk.samples
        let rate = chunk.rate
        guard !samples.isEmpty, rate > 0 else { return }
        Task.detached(priority: .utility) {
            guard TurnReplayStore.store(turnKey: turnKey, samples: samples, rate: rate) != nil else { return }
            Automation.mark("turn-replay: stored \(turnKey) samples=\(samples.count) rate=\(Int(rate))")
        }
    }
}
