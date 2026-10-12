import AVFAudio

/// A consumer of the single microphone source's raw buffers.
protocol AudioCaptureObserver: AnyObject {
    /// `time` is the tap's capture timestamp, carried so components that need a
    /// sample timeline (the system analyzer) can preserve it.
    func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
}

/// The microphone seam. One concrete implementation owns the hardware; tests
/// inject a source that yields synthetic buffers, so consumers never touch an
/// `AVAudioEngine` or the `AVAudioSession`.
protocol AudioSource: AnyObject {
    func addCaptureObserver(_ observer: AudioCaptureObserver)
    func removeCaptureObserver(_ observer: AudioCaptureObserver)
}

/// The playback seam. One concrete implementation owns the output bus; tests
/// inject a sink that records what would have been played.
protocol AudioSink: AnyObject {
    /// Play WAV bytes; returns when playback finishes or is stopped.
    func play(wav: Data) async
    /// Play a PCM buffer; returns when playback finishes or is stopped.
    func play(_ buffer: AVAudioPCMBuffer) async
    /// Play a buffer on repeat until `stopPlayback` (call cues).
    func playLooping(_ buffer: AVAudioPCMBuffer)
    /// Stop whatever is playing and release any waiting `play` call.
    func stopPlayback()
}

/// The app's single microphone source and single playback sink.
///
/// Exactly one `AVAudioEngine`, one input tap, one playback bus, and one
/// `AVAudioSession` configuration exist per process. Capture fans out to
/// observers; every audible thing (TTS, call cues) renders on the playback bus,
/// so that bus is also the echo-cancellation reference. Nothing else may call
/// `installTap`, `setCategory`, or create a playback engine.
///
/// Voice processing stays enabled for the whole run: the AEC filter needs a
/// stable input/output graph, so callers gate by turn, not by toggling the
/// engine (docs/voice-side-channel.md).
final class AudioIO: AudioSource, AudioSink {
    static let shared = AudioIO()

    /// Session/routing profile for the active call.
    enum Profile {
        /// Daemon-streamed call audio. `.default` keeps VoiceProcessingIO from
        /// attenuating playback (docs/troubleshooting.md).
        case liveCall
        /// On-device cascade. `.voiceChat` is VPIO's native AEC mode.
        case voiceAgent
        /// Voice-memo recording: play-and-record so review playback shares the
        /// session, `.default` to match the previous recorder config.
        case recording
    }

    private var engine = AVAudioEngine()
    private var playbackPlayer = AVAudioPlayerNode()
    private let observerLock = NSLock()
    private let captureObservers = NSHashTable<AnyObject>.weakObjects()
    private var profile: Profile?
    private(set) var running = false
    /// True while a queued buffer is playing (cues, TTS). Read by the barge-in
    /// harness; not a public playback state machine.
    private(set) var isPlaying = false
    /// One continuation per queued `play`, so overlapping callers (a cue and a
    /// TTS reply) each resume exactly once instead of clobbering one slot.
    private var pendingPlays: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var sessionObservers: [NSObjectProtocol] = []
    private var restartAfterInterruption = false

    private init() {}

    // MARK: - lifecycle

    /// Configure the session and start the one engine. Idempotent per profile;
    /// a different profile restarts it. Main thread.
    func start(profile: Profile) {
        runOnMain { [self] in
            AVAudioApplication.requestRecordPermission { _ in } // no-op if granted
            if running, self.profile == profile { return }
            if running || self.profile != nil { stopLocked() }
            self.profile = profile
            configureSession(profile)
            restartAfterInterruption = false
            installSessionObservers()
            startEngine()
        }
    }

    /// Stop capture and playback and deactivate the session.
    func stop() {
        runOnMain { [self] in stopLocked() }
    }

    private func stopLocked() {
        guard running || profile != nil else { return }
        stopEngine()
        removeSessionObservers()
        profile = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Automation.mark("audio: stopped")
    }

    private func startEngine() {
        // Fresh engine + player per start: a node cannot be re-attached to a
        // rebuilt graph, and voice processing must be enabled before the
        // playback bus is connected.
        engine = AVAudioEngine()
        playbackPlayer = AVAudioPlayerNode()
        engine.attach(playbackPlayer)
        let input = engine.inputNode
        // Order matters: enable voice processing while the engine is stopped,
        // then connect the playback bus. Connecting first materializes the
        // output graph at the pre-VPIO format and `setVoiceProcessingEnabled`
        // raises an ObjC exception Swift cannot catch (docs/troubleshooting.md,
        // "SIGABRT").
        do {
            try input.setVoiceProcessingEnabled(true)
            Automation.mark("audio: voice-processing enabled profile=\(String(describing: profile))")
        } catch {
            Automation.mark("audio: voice-processing unsupported: \(error.localizedDescription)")
        }
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false, duckingLevel: .min)
        engine.connect(playbackPlayer, to: engine.mainMixerNode, format: nil)

        input.removeTap(onBus: 0) // insurance: installTap aborts if one survived
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, time in
            self?.fanOut(buffer, at: time)
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
            Automation.mark("audio: started profile=\(String(describing: profile))")
        } catch {
            idfonError("idfon audio: engine start failed: \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        playbackPlayer.stop()
        isPlaying = false
        resumePendingPlays()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        running = false
    }

    private func configureSession(_ profile: Profile) {
        let session = AVAudioSession.sharedInstance()
        switch profile {
        case .liveCall:
            // Set the mode in the category call; move the route override last
            // (setMode(.voiceChat) after the override re-evaluates the route).
            try? session.setCategory(
                .playAndRecord, mode: .default,
                options: [.allowBluetoothHFP, .defaultToSpeaker])
            try? session.setPreferredIOBufferDuration(0.01)
        case .voiceAgent:
            try? session.setCategory(
                .playAndRecord, mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP])
        case .recording:
            try? session.setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker])
        }
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        try? session.overrideOutputAudioPort(.speaker)
        Automation.mark(
            "audio: session category=\(session.category.rawValue) mode=\(session.mode.rawValue)"
        )
    }

    private func installSessionObservers() {
        guard sessionObservers.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in self?.handleInterruption(note) })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in self?.handleRouteChange(note) })
    }

    private func removeSessionObservers() {
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        if value == AVAudioSession.InterruptionType.began.rawValue {
            restartAfterInterruption = running
            if running { stopEngine() }
        } else if value == AVAudioSession.InterruptionType.ended.rawValue, restartAfterInterruption {
            restartAfterInterruption = false
            startEngine()
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        else { return }
        stopEngine()
    }

    // MARK: - capture (AudioSource)

    func addCaptureObserver(_ observer: AudioCaptureObserver) {
        runOnMain { [self] in
            observerLock.lock()
            captureObservers.add(observer as AnyObject)
            observerLock.unlock()
        }
    }

    func removeCaptureObserver(_ observer: AudioCaptureObserver) {
        runOnMain { [self] in
            observerLock.lock()
            captureObservers.remove(observer as AnyObject)
            observerLock.unlock()
        }
    }

    /// Copy the list under the lock, then call outside it: an observer must not
    /// be able to deadlock the audio thread.
    private func fanOut(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        observerLock.lock()
        let observers = captureObservers.allObjects
        observerLock.unlock()
        for observer in observers {
            (observer as? AudioCaptureObserver)?.audioCapture(buffer, at: time)
        }
    }

    // MARK: - playback (AudioSink)

    func play(wav: Data) async {
        guard running,
              let buffer = Self.buffer(wav: wav, target: playbackPlayer.outputFormat(forBus: 0))
        else { return }
        await play(buffer)
    }

    func play(_ buffer: AVAudioPCMBuffer) async {
        guard running,
              let converted = Self.convert(buffer, to: playbackPlayer.outputFormat(forBus: 0))
        else { return }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingPlays[id] = continuation
            isPlaying = true
            playbackPlayer.scheduleBuffer(
                converted, at: nil, options: [], completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.finishPlay(id) }
            }
            if !playbackPlayer.isPlaying { playbackPlayer.play() }
        }
    }

    /// Resume exactly once per play: whichever of stop/flush or the completion
    /// callback arrives first wins; the other finds nothing.
    private func finishPlay(_ id: UUID) {
        isPlaying = false
        pendingPlays.removeValue(forKey: id)?.resume()
    }

    private func resumePendingPlays() {
        let pending = pendingPlays
        pendingPlays.removeAll()
        for continuation in pending.values { continuation.resume() }
    }

    func playLooping(_ buffer: AVAudioPCMBuffer) {
        guard running,
              let converted = Self.convert(buffer, to: playbackPlayer.outputFormat(forBus: 0))
        else { return }
        playbackPlayer.scheduleBuffer(converted, at: nil, options: [.loops], completionHandler: nil)
        isPlaying = true
        if !playbackPlayer.isPlaying { playbackPlayer.play() }
    }

    func stopPlayback() {
        playbackPlayer.stop()
        isPlaying = false
        resumePendingPlays()
    }

    // MARK: - PCM helpers

    /// Decode WAV and convert to `target`. `nil` on any decode error.
    static func buffer(wav: Data, target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idfon-audioio.wav")
        guard (try? wav.write(to: url)) != nil,
              let file = try? AVAudioFile(forReading: url),
              let input = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil
        else { return nil }
        return convert(input, to: target)
    }

    /// Convert `buffer` to `target`; returns it unchanged when it already matches.
    static func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == target.sampleRate,
           buffer.format.channelCount == target.channelCount,
           buffer.format.commonFormat == target.commonFormat {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: target) else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        // One second of headroom so the converter's output buffer never fills.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            + AVAudioFrameCount(target.sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return nil }
        return output
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}