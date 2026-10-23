import AVFAudio
import Foundation

/// `-tygerab kokoro|phonon`: scripted falsification run for the "turn-model
/// behavior is TTS-shaped" hypothesis. One fixed script — a user utterance, a
/// reply through the selected engine, a mid-reply interruption — driven
/// through the REAL turn shadow (both channels: scripted mic feed +
/// PlaybackBus agent stream) so the only variable between runs is the engine's
/// playback timing (Kokoro whole-clip vs Phonon streaming). Decisions and
/// timeline events are marked `tygerab t=…`; diff the two runs' traces.
///
/// v1 logs decisions without reacting to them (fixed schedule): it measures
/// whether the heads behave differently under the two second-ears, not the
/// full barge-stop loop.
enum TygerAB {
    /// Retained: AudioMeter holds observers weakly.
    private final class DummyCapture: AudioCaptureObserver {
        func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    }

    @MainActor
    static func run(engine backend: String) {
        let t0 = Date()
        func mark(_ s: String) {
            Automation.mark(String(format: "tygerab t=%.2f %@", -t0.timeIntervalSinceNow, s))
        }
        mark("start engine=\(backend)")
        guard let ttsBackend = TtsBackend(rawValue: backend) else {
            mark("FAIL unknown engine \(backend)")
            exit(2)
        }

        // Bring the shared meter up (the bus must render for PlaybackBus to
        // fan the agent channel into the shadow) and start the shadow.
        let dummy = DummyCapture()
        AudioMeter.addCaptureObserver(dummy)
        Task { @MainActor in
            let shadow = await Task.detached { TurnShadow.start() }.value
            guard let shadow else {
                mark("FAIL no turn model")
                exit(2)
            }
            shadow.onDecision = { kind in mark("decision \(kind)") }

            // Scripted "user" audio: Apple TTS utterances (deterministic).
            // Sequential: synthesizePCM shares one synthesizer property and one
            // temp filename on OnDeviceVoice.shared — concurrent calls clobber
            // each other and both time out.
            let user1 = "Hi, I was hoping you could get me a summary of the meeting notes from yesterday."
            let user2 = "Sorry, quick question before you start."
            let reply =
                "Sure, I can help with that. Let me walk you through it step by step, "
                + "and you can stop me at any time if something is unclear."
            let p1 = await Task.detached { OnDeviceVoice.shared.synthesizePCM(user1) }.value
            let p2 = await Task.detached { OnDeviceVoice.shared.synthesizePCM(user2) }.value
            guard let p1, let p2 else {
                mark("FAIL user audio synth")
                exit(2)
            }
            let u1 = floats(p1)
            let u2 = floats(p2)

            // Wait for the meter to actually run before any playback.
            for _ in 0..<50 where !AudioMeter.shared.running {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            mark("meter running=\(AudioMeter.shared.running) user1=\(u1.count) user2=\(u2.count)")

            // Phase 1: the user speaks (~4 s, real-time paced).
            shadow.setMode("listen")
            mark("user1 start")
            await feed(u1, rate: Double(p1.rate), shadow: shadow, mark: mark)
            mark("user1 end")
            try? await Task.sleep(nanoseconds: 400_000_000)

            // Phase 2: the agent replies through the engine under test. The
            // engine's own marks carry its latency (kokoro: "wav … in Xms";
            // phonon: "first audio Xms"); this is the A/B variable.
            shadow.setMode("speaking")
            mark("reply start")
            let tts = SpeechEngines.makeTts(ttsBackend)
            await tts.prepare()
            let speakTask = Task { @MainActor in
                await tts.speak(reply)
                mark("reply end")
            }

            // Phase 3: the user interrupts mid-reply (~1.2 s in), a fixed
            // schedule — decisions are logged, not acted on (v1).
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            mark("interrupt start")
            shadow.setMode("listen")  // the app flips on BARGE; scripted here
            await feed(u2, rate: Double(p2.rate), shadow: shadow, mark: mark)
            mark("interrupt end")

            await speakTask.value
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            shadow.stop()
            mark("done")
            _ = dummy  // keep alive until here (the meter holds it weakly)
            exit(0)
        }
    }

    /// Feed samples paced at wall-clock rate so the shadow's 320 ms hops pair
    /// 1:1 like they do off the live tap.
    @MainActor
    private static func feed(
        _ samples: [Float], rate: Double, shadow: TurnShadow,
        mark: (String) -> Void
    ) async {
        let chunk = Int(rate * 0.2)
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            shadow.feed(Array(samples[index..<end]), rate: rate)
            index = end
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// 16-bit mono PCM bytes -> floats (OnDeviceVoice.synthesizePCM's output).
    private static func floats(_ pcm: (rate: UInt32, data: Data)) -> [Float] {
        pcm.data.withUnsafeBytes { raw in
            let s16 = raw.bindMemory(to: Int16.self)
            return s16.map { Float($0) / 32768.0 }
        }
    }
}
