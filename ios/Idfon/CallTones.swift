import AVFoundation
import Foundation

/// Cross-component call feedback: the call singletons post a short line here
/// when a call cannot start, and the chat surfaces it as a transient status
/// (iOS `showCallStatus`, macOS `showBanner`).
extension Notification.Name {
    static let idfonCallStatus = Notification.Name("idfon.call.status")
}

enum CallFeedback {
    static func post(_ text: String) {
        guard !text.isEmpty else { return }
        NotificationCenter.default.post(
            name: .idfonCallStatus, object: nil, userInfo: ["text": text])
    }
}

/// In-app call sounds: ringback while dialing, incoming ringtone, and short
/// answer/end cues.
///
/// It owns no `AVAudioEngine`: every cue is synthesized to PCM and rendered on
/// the app's single playback sink (`AudioIO`), so cues share the call's output
/// bus (and its AEC reference) instead of racing it with a second engine.
/// Tones are synthesized so no assets ship; swap `toneBuffer` for an asset load
/// if/when real ringtones are added. When CallKit lands it supplies the system
/// incoming ringtone, so the `.ringtone` case becomes the non-CallKit fallback.
final class CallTonePlayer {
    static let shared = CallTonePlayer()

    enum Tone { case ringback, ringtone, answered, ended }

    private let sampleRate = 48_000.0
    private var current: Tone?
    /// Injected for tests; the app renders cues on the single playback sink.
    private let sink: AudioSink

    init(sink: AudioSink = AudioIO.shared) {
        self.sink = sink
    }

    /// Start (or switch to) a looping tone or one-shot cue. Idempotent.
    func start(_ tone: Tone) {
        runOnMain { [self] in
            if current == tone {
                Automation.mark("call-tone: \(tone) already current (no-op)")
                return
            }
            Automation.mark("call-tone: \(tone)")
            current = tone
            sink.stopPlayback()
            guard let buffer = toneBuffer(tone) else { return }
            switch tone {
            case .ringback, .ringtone:
                sink.playLooping(buffer)
            case .answered, .ended:
                Task { await sink.play(buffer) }
            }
        }
    }

    /// Stop whatever is playing. Idempotent.
    func stop() {
        runOnMain { [self] in
            guard current != nil else { return }
            current = nil
            sink.stopPlayback()
        }
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    // MARK: - synthesis

    private func format() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// One buffer per pattern; looping tones repeat it, cues play it once.
    private func toneBuffer(_ tone: Tone) -> AVAudioPCMBuffer? {
        switch tone {
        case .ringback:
            return loopBuffer([440], onMs: 1_000, offMs: 2_000, amplitude: 0.18)
        case .ringtone:
            return loopBuffer([480, 620], onMs: 1_000, offMs: 2_000, amplitude: 0.20)
        case .answered:
            return cueBuffer([(660, 150)], amplitude: 0.15)
        case .ended:
            // Two descending beeps, like the tail of a toll call.
            return cueBuffer([(480, 150), (0, 70), (370, 220)], amplitude: 0.16)
        }
    }

    /// A one-shot cue from (frequency-Hz, duration-ms) segments; 0 Hz is silence.
    private func cueBuffer(
        _ segments: [(freq: Double, ms: Int)],
        amplitude: Double
    ) -> AVAudioPCMBuffer? {
        let totalMs = segments.reduce(0) { $0 + $1.ms }
        let frames = AVAudioFrameCount(Double(totalMs) / 1_000.0 * sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format(), frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let fadeFrames = max(1, Int(0.005 * sampleRate)) // 5 ms click guard
        var index = 0
        for (freq, ms) in segments {
            let segmentFrames = Int(Double(ms) / 1_000.0 * sampleRate)
            for offset in 0..<segmentFrames {
                guard index < Int(frames) else { break }
                defer { index += 1 }
                guard freq > 0 else {
                    channel[index] = 0
                    continue
                }
                let t = Double(offset) / sampleRate
                var sample = sin(2 * .pi * freq * t)
                if offset < fadeFrames {
                    sample *= Double(offset) / Double(fadeFrames)
                } else if offset > segmentFrames - fadeFrames {
                    sample *= Double(segmentFrames - offset) / Double(fadeFrames)
                }
                channel[index] = Float(sample * amplitude)
            }
        }
        while index < Int(frames) { channel[index] = 0; index += 1 }
        return buffer
    }

    /// A looping ring pattern: `onMs` of tone then `offMs` of silence.
    private func loopBuffer(
        _ frequencies: [Double],
        onMs: Int,
        offMs: Int,
        amplitude: Double
    ) -> AVAudioPCMBuffer? {
        let totalMs = onMs + offMs
        let frames = AVAudioFrameCount(Double(totalMs) / 1_000.0 * sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format(), frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let onFrames = Int(Double(onMs) / 1_000.0 * sampleRate)
        let fadeFrames = max(1, Int(0.005 * sampleRate)) // 5 ms click guard
        for index in 0..<Int(frames) {
            guard index < onFrames else {
                channel[index] = 0
                continue
            }
            let t = Double(index) / sampleRate
            var sample = frequencies.reduce(0.0) { $0 + sin(2 * .pi * $1 * t) }
            sample /= Double(frequencies.count)
            if index < fadeFrames {
                sample *= Double(index) / Double(fadeFrames)
            } else if index > onFrames - fadeFrames {
                sample *= Double(onFrames - index) / Double(fadeFrames)
            }
            channel[index] = Float(sample * amplitude)
        }
        return buffer
    }
}