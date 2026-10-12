import AVFoundation

/// Shell-side live-call capture: consumes the single microphone source
/// (`AudioIO`), converts to the contact profile's mono f32 sample rate (48 kHz
/// by default), and pushes it through `media_audio_push_samples`.
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
    /// Injected for tests; the app uses the single real microphone source.
    private let source: AudioSource
    /// Guards the converter against the audio thread's `audioCapture` and main's
    /// start/stop. AVAudioConverter is not thread-safe.
    private let lock = NSLock()

    init(source: AudioSource = AudioIO.shared) {
        self.source = source
    }

    func start(sampleRate: Int = 48_000, completion: (() -> Void)? = nil) {
        runOnMain { [weak self] in
            guard let self else { completion?(); return }
            guard sampleRate == 24_000 || sampleRate == 48_000 else {
                completion?()
                return
            }
            self.targetSampleRate = sampleRate
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
                    idfonLog("idfon audio push: started (\(self.targetSampleRate) Hz)")
                    completion?()
                }
            }
        }
    }

    func startForCall(sampleRate: Int = 48_000) async -> Bool {
        await withCheckedContinuation { continuation in
            start(sampleRate: sampleRate) { continuation.resume(returning: self.running) }
        }
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

    /// Convert to the profile rate and push. Runs on the audio thread; the
    /// converter is built once from the first buffer's format.
    func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        if converter == nil {
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(targetSampleRate),
                channels: 1,
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
              let channel = output.floatChannelData?[0] else { return }
        media_audio_push_samples(channel, Int(output.frameLength))
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}