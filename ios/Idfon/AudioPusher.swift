import AVFoundation

/// Shell-side call capture: taps the AVAudioEngine input, converts to the
/// dylib's ingest format (48 kHz mono f32) and pushes it through
/// `media_audio_push_samples`.
///
/// In the dylib's "push" mode the Rust side does not open the microphone, so
/// this tap is the call's sole capture. It is also the source a call waveform
/// can meter (issue #7), with no second mic client racing the tap.
final class AudioPusher {
    static let shared = AudioPusher()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private(set) var running = false
    private var observers: [NSObjectProtocol] = []
    private var restartAfterInterruption = false

    private static let pipelineFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private init() {}

    func start() {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard granted, let self, !self.running else { return }
            do {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
                try session.setActive(true)
                let input = self.engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard let converter = AVAudioConverter(from: format, to: Self.pipelineFormat) else {
                    NSLog("idfon audio push: no converter for \(format)")
                    return
                }
                self.converter = converter
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                    self?.push(buffer)
                }
                try self.engine.start()
                self.installObservers(session)
                self.running = true
                NSLog("idfon audio push: started (\(format))")
            } catch {
                NSLog("idfon audio push failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        restartAfterInterruption = false
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        removeObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        running = false
        NSLog("idfon audio push: stopped")
    }

    private func installObservers(_ session: AVAudioSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let self, let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            if value == AVAudioSession.InterruptionType.began.rawValue {
                self.restartAfterInterruption = self.running
                if self.running {
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.engine.stop()
                    self.converter = nil
                }
                self.running = false
            } else if value == AVAudioSession.InterruptionType.ended.rawValue, self.restartAfterInterruption {
                self.restartAfterInterruption = false
                self.start()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            self?.stop()
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    deinit {
        stop()
        removeObservers()
    }

    private func push(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.pipelineFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up)
        ) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.pipelineFormat,
            frameCapacity: capacity
        ) else { return }

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
}
