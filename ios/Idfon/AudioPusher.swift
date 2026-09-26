import AVFoundation

/// Shell-side call capture: taps the AVAudioEngine input, converts to the
/// contact profile's mono f32 sample rate (48 kHz by default), and pushes it through
/// `media_audio_push_samples`.
///
/// In the dylib's "push" mode the Rust side does not open the microphone, so
/// this tap is the call's sole capture. It is also the source a call waveform
/// can meter (issue #7), with no second mic client racing the tap.
///
/// Threading: AVAudioEngine is not thread-safe and `installTap` aborts the
/// process with an ObjC exception when a tap already exists (Swift cannot
/// catch it). Every engine mutation therefore runs on the main queue, and a
/// generation counter discards permission callbacks that raced a stop or a
/// newer start.
final class AudioPusher {
    static let shared = AudioPusher()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private(set) var running = false
    private var tapInstalled = false
    private var generation = 0
    private var startInFlight = false
    /// Completions waiting on the in-flight start attempt; called on main
    /// once the attempt settles (they read `running` for the outcome).
    private var pendingStarts: [() -> Void] = []
    private var observers: [NSObjectProtocol] = []
    private var restartAfterInterruption = false
    private var targetSampleRate = 48_000

    private func pipelineFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        )!
    }

    private init() {}

    func start(sampleRate: Int = 48_000, completion: (() -> Void)? = nil) {
        runOnMain { [weak self] in
            guard let self else { completion?(); return }
            guard sampleRate == 24_000 || sampleRate == 48_000 else {
                completion?()
                return
            }
            self.targetSampleRate = sampleRate
            if self.running {
                completion?()
                return
            }
            if let completion { self.pendingStarts.append(completion) }
            guard !self.startInFlight else { return } // joins the in-flight attempt
            self.startInFlight = true
            self.generation += 1
            let generation = self.generation
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async { self?.beginStart(granted: granted, generation: generation) }
            }
        }
    }

    func startForCall(sampleRate: Int = 48_000) async -> Bool {
        await withCheckedContinuation { continuation in
            start(sampleRate: sampleRate) {
                continuation.resume(returning: self.running)
            }
        }
    }

    func stop() {
        runOnMain { self.teardown(deactivate: true) }
    }

    // MARK: - Internals (main queue only)

    private func beginStart(granted: Bool, generation gen: Int) {
        defer { settle() }
        guard gen == self.generation, granted, !running, !tapInstalled else {
            startInFlight = false
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            try session.setActive(true)
            // Route before mode: `.voiceChat` bakes VoiceProcessingIO's output
            // gain from the route active at mode-set time, so set the speaker
            // first or the output stays at the quiet receiver gain.
            try? session.overrideOutputAudioPort(.speaker)
            try session.setMode(.voiceChat)
            // VoIP-standard 10 ms capture IO (WebRTC does the same): small
            // bursts keep the sender FIFO near-empty. Best effort — HFP or
            // device limits may grant more.
            try? session.setPreferredIOBufferDuration(0.01)
            let input = engine.inputNode
            // Insurance: installTap aborts if a tap somehow survived.
            input.removeTap(onBus: 0)
            tapInstalled = false
            let format = input.outputFormat(forBus: 0)
            let pipelineFormat = pipelineFormat()
            guard let converter = AVAudioConverter(from: format, to: pipelineFormat) else {
                NSLog("idfon audio push: no converter for \(format)")
                startInFlight = false
                return
            }
            self.converter = converter
            self.outputFormat = pipelineFormat
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                self?.push(buffer)
            }
            tapInstalled = true
            try engine.start()
            installObservers(session)
            running = true
            startInFlight = false
            NSLog("idfon audio push: started (\(format))")
        } catch {
            NSLog("idfon audio push failed: \(error.localizedDescription)")
            captureTeardown()
        }
    }

    /// Full stop: engine teardown + observers + session deactivation.
    private func teardown(deactivate: Bool) {
        restartAfterInterruption = false
        generation += 1
        captureTeardown()
        removeObservers()
        if deactivate {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        NSLog("idfon audio push: stopped")
    }

    /// Engine-side teardown (also the interruption path): clears the tap and
    /// engine, settles any pending start attempts, keeps observers.
    private func captureTeardown() {
        generation += 1
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        converter = nil
        outputFormat = nil
        running = false
        startInFlight = false
        settle()
    }

    /// Calls queued start completions; they read `running` for the outcome.
    private func settle() {
        let pending = pendingStarts
        pendingStarts = []
        pending.forEach { $0() }
    }

    private func installObservers(_ session: AVAudioSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let self, let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            if value == AVAudioSession.InterruptionType.began.rawValue {
                self.restartAfterInterruption = self.running
                if self.running {
                    self.captureTeardown()
                }
            } else if value == AVAudioSession.InterruptionType.ended.rawValue, self.restartAfterInterruption {
                self.restartAfterInterruption = false
                self.start(sampleRate: self.targetSampleRate)
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

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func push(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }
        let ratio = Double(targetSampleRate) / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up)
        ) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
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
