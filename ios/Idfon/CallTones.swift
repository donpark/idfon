import AVFoundation
import Foundation

/// In-app call sounds: ringback while dialing, incoming ringtone, and short
/// answer/end cues.
///
/// Threading: the AVAudioEngine lives entirely on a private serial queue.
/// Callers (the main thread) only record intent via `start`/`stop`; no engine
/// setup, buffer generation, or scheduling runs on the UI thread.
///
/// Tones are synthesized so no assets ship; swap `toneBuffer` for an asset load
/// if/when real ringtones are added. When CallKit lands it supplies the system
/// incoming ringtone, so the `.ringtone` case becomes the non-CallKit fallback.
final class CallTonePlayer {
    static let shared = CallTonePlayer()

    enum Tone { case ringback, ringtone, answered, ended }

    private let queue = DispatchQueue(label: "idfon.call-tones")
    private let sampleRate = 48_000.0
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var current: Tone?

    /// Start (or switch to) a looping tone or one-shot cue. Idempotent.
    func start(_ tone: Tone) {
        queue.async { self.startLocked(tone) }
    }

    /// Stop whatever is playing and release the engine. Idempotent.
    func stop() {
        queue.async { self.stopLocked() }
    }

    // MARK: - queue-confined

    private func startLocked(_ tone: Tone) {
        if current == tone, player?.isPlaying == true { return }
        stopLocked()
        guard ensureStartedLocked(), let player, let buffer = toneBuffer(tone) else { return }
        current = tone
        switch tone {
        case .ringback, .ringtone:
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        case .answered, .ended:
            player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                guard let self else { return }
                self.queue.async { if self.current == tone { self.stopLocked() } }
            }
        }
    }

    private func ensureStartedLocked() -> Bool {
        if let engine, engine.isRunning { return true }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            idfonError("idfon call tones: engine start failed: \(error)")
            return false
        }
        player.play()
        self.engine = engine
        self.player = player
        return true
    }

    private func stopLocked() {
        current = nil
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
    }

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