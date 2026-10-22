import AVFoundation

/// Shell-side live-call capture: consumes the single microphone source
/// (`AudioIO`), converts to the contact profile's f32 sample rate (48 kHz by
/// default) and channel count (mono by default, interleaved stereo on the
/// headset route — docs/stereo-calls.md), and pushes it through
/// `media_audio_push_samples` / `media_audio_push_frames`.
///
/// In the dylib's "push" mode the Rust side does not open the microphone, so
/// this is the live call's only capture path. It owns no `AVAudioEngine`, tap,
/// or session configuration — `AudioIO` owns those, and this is just an
/// `AudioCaptureObserver`.
final class AudioPusher: AudioCaptureObserver {
    static let shared = AudioPusher()

    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private(set) var running = false
    private var targetSampleRate = 48_000
    /// 1 mono, 2 interleaved stereo; must match the publisher started with
    /// `media_live_start_with_profile` (mismatched pushes are dropped there).
    private(set) var targetChannels = 1
    /// Injected for tests; the app uses the single real microphone source.
    private let source: AudioSource
    /// Guards the converter against the audio thread's `audioCapture` and main's
    /// start/stop. AVAudioConverter is not thread-safe.
    private let lock = NSLock()

    init(source: AudioSource = AudioIO.shared) {
        self.source = source
    }

    func start(sampleRate: Int = 48_000, channels: Int = 0, completion: (() -> Void)? = nil) {
        runOnMain { [weak self] in
            guard let self else { completion?(); return }
            guard sampleRate == 24_000 || sampleRate == 48_000 else {
                completion?()
                return
            }
            self.targetSampleRate = sampleRate
            // 0 = follow the call's audio mode (the panel's radio group).
            self.targetChannels = max(1, min(2, channels == 0 ? AudioIO.captureChannelsForCall() : channels))
            if self.running { completion?(); return }
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { completion?(); return }
                    guard granted, !self.running else { completion?(); return }
                    AudioIO.shared.start(profile: .liveCall)
                    self.source.addCaptureObserver(self)
                    self.lock.lock()
                    self.running = true
                    self.lock.unlock()
                    idfonLog("idfon audio push: started (\(self.targetSampleRate) Hz, \(self.targetChannels) ch)")
                    completion?()
                }
            }
        }
    }

    func startForCall(sampleRate: Int = 48_000, channels: Int = 0) async -> Bool {
        await withCheckedContinuation { continuation in
            start(sampleRate: sampleRate, channels: channels) { continuation.resume(returning: self.running) }
        }
    }

    /// Switch the push channel count (a mode change re-publishes the leg):
    /// the converter rebuilds on the next buffer.
    func retarget(channels: Int) {
        lock.lock()
        targetChannels = max(1, min(2, channels))
        converter = nil
        outputFormat = nil
        lock.unlock()
    }

    func stop() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.source.removeCaptureObserver(self)
            self.lock.lock()
            self.converter = nil
            self.outputFormat = nil
            self.running = false
            self.lock.unlock()
            AudioIO.shared.stop()
            idfonLog("idfon audio push: stopped")
        }
    }

    /// Convert to the profile rate/channels and push. Runs on the audio thread;
    /// the converter is built once from the first buffer's format. Mono sources
    /// on a stereo call are upmixed so the track layout is fixed by the call,
    /// not by whatever the first buffer happened to carry.
    func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        if converter == nil {
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(targetSampleRate),
                channels: AVAudioChannelCount(targetChannels),
                interleaved: false
            )
            outputFormat = format
            if let format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            if converter == nil {
                idfonLog("idfon audio push: no converter for \(buffer.format)")
            }
        }
        let converter = self.converter
        let outputFormat = self.outputFormat
        lock.unlock()
        guard let converter, let outputFormat else { return }

        let ratio = Double(targetSampleRate) / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error,
              output.frameLength > 0,
              let planes = output.floatChannelData else { return }
        let frames = Int(output.frameLength)
        if targetChannels == 1 {
            media_audio_push_samples(planes[0], frames)
        } else {
            // Interleaved f32: the encoder's native layout (`Format::F32`).
            var interleaved = [Float](repeating: 0, count: frames * targetChannels)
            for frame in 0..<frames {
                for channel in 0..<targetChannels {
                    interleaved[frame * targetChannels + channel] = planes[channel][frame]
                }
            }
            interleaved.withUnsafeBufferPointer { buffer in
                media_audio_push_frames(buffer.baseAddress, frames, UInt32(targetChannels))
            }
        }
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}