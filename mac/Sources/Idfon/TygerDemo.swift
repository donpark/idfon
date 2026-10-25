import AVFAudio
import Foundation

/// `-tygerdemo <user.wav> <script.json>`: replay the tyger-s2s demo's USER
/// channel (diarized out of the demo mix: `scripts`/FluidAudio nemotron3 +
/// parakeet) through the real turn pipeline and react exactly as
/// `VoiceAgentSession.turnDecision` does — so the demo's overlapping and
/// interrupting-with-feedback behavior replays decision-driven, not scheduled:
///
/// - BACKCHANNEL speaks a "mm-hm" over the caller (`FeedbackEar` keeps it out
///   of the second ear, like production);
/// - ENDPOINT speaks the demo's reply text through the mouth under test;
/// - BARGE stops playback (the reply is cut where the caller cut in).
///
/// The caller's stream runs on the demo's wall clock, so interruptions land
/// where they landed in the demo. Marks are `tygerdemo t=…`; diff them against
/// the demo's own events (script.json `demo`: bc / barges / reply_starts).
/// Replica for testing: replies are scripted text, no LLM and no device.
enum TygerDemo {
    struct Script: Decodable {
        let replies: [String]
        let demo: Demo
        struct Demo: Decodable {
            let bc: [Double]
            let ack: [Double]
            let barges: [Double]
            let reply_starts: [Double]
            let user_turns: [[Double]]
        }
    }

    /// Retained: AudioMeter holds observers weakly and must see one to start.
    private final class DummyCapture: AudioCaptureObserver {
        func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    }

    @MainActor
    static func run(userWav: String, script: String) {
        let t0 = Date()
        func mark(_ s: String) {
            Automation.mark(String(format: "tygerdemo t=%.2f %@", -t0.timeIntervalSinceNow, s))
        }
        guard let scriptData = FileManager.default.contents(atPath: script),
              let plan = try? JSONDecoder().decode(Script.self, from: scriptData),
              let user = loadWav(userWav)
        else {
            mark("FAIL load wav/script")
            exit(2)
        }
        mark("start replies=\(plan.replies.count) user=\(user.count) samples")
        for (i, t) in plan.demo.reply_starts.enumerated() { mark(String(format: "demo reply %d at %.2f", i, t)) }
        for t in plan.demo.bc + plan.demo.ack { mark(String(format: "demo bc at %.2f", t)) }
        for t in plan.demo.barges { mark(String(format: "demo barge at %.2f", t)) }

        let dummy = DummyCapture()
        AudioMeter.addCaptureObserver(dummy)
        Task { @MainActor in
            let shadow = await Task.detached { TurnShadow.start() }.value
            guard let shadow else {
                mark("FAIL no turn model")
                exit(2)
            }
            #if PHONON_TTS
            let tts: TtsEngine = PhononTtsEngine()
            #else
            let tts: TtsEngine = SpeechEngines.makeTts(SpeechEngines.ttsBackend)
            #endif
            await tts.prepare()
            let driver = Driver(
                shadow: shadow, tts: tts, replies: plan.replies,
                bcs: (plan.demo.bc + plan.demo.ack).sorted(), mark: mark)
            shadow.onDecision = { kind in Task { @MainActor in driver.decision(kind) } }

            for _ in 0..<50 where !AudioMeter.shared.running {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            mark("meter running=\(AudioMeter.shared.running)")
            shadow.setMode("listen")
            mark("user stream start")
            await feed(user, rate: 16000, shadow: shadow) { streamT in
                // The timeline's backchannels: the demo's own mm-hm moments,
                // fired at their stream time (the student tier's bc head does
                // not fire; ENDPOINT/BARGE stay model-driven).
                while let first = driver.nextBc, first <= streamT {
                    driver.popBc()
                    driver.decision("BACKCHANNEL")
                }
            }
            mark("user stream end")
            await driver.finish()
            shadow.stop()
            mark("done")
            _ = dummy
            exit(0)
        }
    }

    /// The decision-driven replica of VoiceAgentSession's turn handling.
    @MainActor
    private final class Driver {
        private let shadow: TurnShadow
        private let tts: TtsEngine
        private let replies: [String]
        private let mark: (String) -> Void
        private var nextReply = 0
        private var speaking = false
        private var speakTask: Task<Void, Never>?
        private var feedbackTask: Task<Void, Never>?
        private var lastFeedbackAt: Date?
        /// Timeline backchannels still to fire (demo stream time, seconds).
        private var bcs: [Double]
        var nextBc: Double? { bcs.first }

        init(shadow: TurnShadow, tts: TtsEngine, replies: [String], bcs: [Double],
            mark: @escaping (String) -> Void) {
            self.shadow = shadow
            self.tts = tts
            self.replies = replies
            self.bcs = bcs
            self.mark = mark
        }

        func popBc() {
            if !bcs.isEmpty { bcs.removeFirst() }
        }

        /// Mirror of VoiceAgentSession.turnDecision (BACKCHANNEL → utterFeedback,
        /// BARGE → tts.stop, ENDPOINT → commit; here commit = speak the next reply).
        func decision(_ kind: String) {
            switch kind {
            case "ENDPOINT":
                guard !speaking else { return }
                mark("decision ENDPOINT -> reply")
                Task { await startReply() }
            case "BARGE":
                guard speaking else { return }
                mark("decision BARGE -> stop playback")
                tts.stop()
            case "BACKCHANNEL":
                utterFeedback()
            default:
                break
            }
        }

        /// Mirror of VoiceAgentSession.utterFeedback: same gap rule, same
        /// FeedbackEar window, never flips the mode (the caller keeps the floor).
        private func utterFeedback() {
            guard !speaking, feedbackTask == nil else {
                if speaking { mark("feedback skipped: agent speaking") }
                return
            }
            if let at = lastFeedbackAt, Date().timeIntervalSince(at) < 1.2 { return }
            lastFeedbackAt = Date()
            mark("decision BACKCHANNEL -> feedback")
            feedbackTask = Task { @MainActor in
                await FeedbackEar.suppress { await self.tts.speak("Mm-hmm.") }
                self.mark("feedback done")
                self.feedbackTask = nil
            }
        }

        /// Mirror of VoiceAgentSession.speak's prologue + turn: a reply
        /// supersedes an in-flight "mm-hm" and speaks the demo's reply text.
        private func startReply() async {
            guard nextReply < replies.count else {
                mark("reply: none left")
                return
            }
            if feedbackTask != nil {
                tts.stop()
                await feedbackTask?.value
                feedbackTask = nil
            }
            let text = replies[nextReply]
            nextReply += 1
            speaking = true
            shadow.setMode("speaking")
            mark("reply \(nextReply - 1) start chars=\(text.count)")
            speakTask = Task { @MainActor in
                await self.tts.speak(text)
                self.mark("reply end")
                self.speaking = false
                self.shadow.setMode("listen")
            }
        }

        /// Let the last reply finish before the summary.
        func finish() async {
            await speakTask?.value
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Feed samples paced at wall-clock rate so the shadow's 320 ms hops pair
    /// 1:1 like they do off the live tap (TygerAB's feed). `onTick` sees the
    /// stream position (seconds) at each chunk.
    @MainActor
    private static func feed(
        _ samples: [Float], rate: Double, shadow: TurnShadow,
        onTick: (Double) -> Void
    ) async {
        let chunk = Int(rate * 0.2)
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            shadow.feed(Array(samples[index..<end]), rate: rate)
            index = end
            onTick(Double(index) / rate)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// 16-bit mono WAV -> floats (the preprocessed demo user channel).
    private static func loadWav(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        guard let ch = buf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }
}
