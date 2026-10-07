import AVFAudio
import Foundation
import FluidAudio

/// Parakeet Redux (moondream) recognizer via FluidAudio's
/// `SlidingWindowAsrManager`.
///
/// Redux is a batch sliding-window model, but the manager exposes it as a
/// stream: we push mic buffers and it emits volatile/confirmed
/// `transcriptionUpdates`, which map onto the loop's partial/final model.
///
/// iOS 18+, ANE. First run downloads the ~183 MB encoder and compiles it for
/// Core ML (minutes); failures surface as `start` throwing, and the caller
/// falls back to the system recognizer.
@available(iOS 18.0, *)
final class ParakeetReduxAsr: AsrEngine, TtsPlayer {
    let name = "parakeet-redux"

    private let engine = AVAudioEngine()
    /// TTS playback bus. Attached before voice processing is enabled so VPIO has
    /// an output bus to use as its echo-cancellation reference.
    private let playbackPlayer = AVAudioPlayerNode()
    private var playbackFinish: (() -> Void)?
    private var scheduledBuffer: AVAudioPCMBuffer?
    private let gateLock = NSLock()
    private var gated = false
    private var manager: SlidingWindowAsrManager?
    private var feedTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var onText: ((String, Bool) -> Void)?
    private var started = false

    // Single-flight warm task: download + CoreML-compile ahead of the first
    // turn so `start` doesn't pay for it. The loaded instance is dropped;
    // FluidAudio reuses the compiled artifacts on disk.
    private static let warmLock = NSLock()
    private static var warmTask: Task<Void, Never>?

    func prepare() async { await Self.warmCache() }

    static func warmCache() async {
        let task = warmLock.withLock { () -> Task<Void, Never> in
            if let existing = warmTask { return existing }
            let created = Task {
                let throttle = ProgressThrottle()
                Automation.mark("voice: parakeet prewarming")
                do {
                    _ = try await AsrModels.downloadAndLoad(version: .redux) { progress in
                        if throttle.shouldLog(progress.fractionCompleted) {
                            Automation.mark("voice: parakeet download \(Int(progress.fractionCompleted * 100))%")
                        }
                    }
                    Automation.mark("voice: parakeet prewarmed")
                } catch {
                    Automation.mark("voice: parakeet prewarm failed \(error.localizedDescription)")
                }
            }
            warmTask = created
            return created
        }
        await task.value
        warmLock.withLock { warmTask = nil }  // allow a retry after a transient failure
    }

    func start(
        enableVoiceProcessing: Bool,
        onText: @escaping (String, Bool) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        self.onText = onText
        Automation.mark("voice: parakeet initializing")
        let throttle = ProgressThrottle()
        let models = try await AsrModels.downloadAndLoad(version: .redux) { progress in
            if throttle.shouldLog(progress.fractionCompleted) {
                Automation.mark("voice: parakeet download \(Int(progress.fractionCompleted * 100))%")
            }
        }
        let manager = SlidingWindowAsrManager()
        try await manager.loadModels(models)
        try await manager.startStreaming(source: .microphone)
        self.manager = manager

        // Feed the actor one ordered buffer stream (its `streamAudio` is
        // actor-isolated, so the tap can't call it directly).
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .unbounded
        )
        bufferContinuation = continuation
        feedTask = Task {
            for await buffer in stream {
                if Task.isCancelled { break }
                await manager.streamAudio(buffer)
            }
        }

        updatesTask = Task { [weak self] in
            let updates = await manager.transcriptionUpdates
            for await update in updates {
                if Task.isCancelled { break }
                self?.onText?(update.text, update.isConfirmed)
            }
        }

        // Attach the playback graph before enabling voice processing: VPIO
        // derives its AEC reference from the output bus, so enabling it with no
        // playback bus attached both skips cancellation and can drop the output
        // level (docs/voice-side-channel.md).
        engine.attach(playbackPlayer)
        engine.connect(playbackPlayer, to: engine.mainMixerNode, format: nil)

        let input = engine.inputNode
        // AEC: enable voice processing on the input node (parity with
        // `SystemSpeechTranscriber`). Without it the live mic hears the agent's
        // own TTS during barge-in and Parakeet re-sends it as the caller's turn.
        if enableVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                Automation.mark("voice: voice-processing enabled")
            } catch {
                Automation.mark("voice: voice-processing unsupported: \(error.localizedDescription)")
            }
            // Keep the call cue tones (a separate engine) from being ducked as
            // "other audio" while VPIO runs.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, !self.isGated else { return }
            self.bufferContinuation?.yield(buffer)
        }
        engine.prepare()
        try engine.start()
        started = true
        Automation.mark("voice: parakeet ready")
        _ = onError  // streaming errors are recovered inside the manager
    }

    func pause() { setGated(true) }

    func resume() {
        setGated(false)
        if started, !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    func stop() {
        guard started || manager != nil else { return }
        started = false
        stopPlayback()
        updatesTask?.cancel()
        updatesTask = nil
        feedTask?.cancel()
        feedTask = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let manager = self.manager
        self.manager = nil
        Task { await manager?.cleanup() }
    }

    private var isGated: Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        return gated
    }

    private func setGated(_ value: Bool) {
        gateLock.lock()
        gated = value
        gateLock.unlock()
    }

    // MARK: - TtsPlayer

    /// Render synthesized WAV on the VPIO engine and return when it has played.
    func play(wav: Data) async {
        guard started else { return }
        let target = playbackPlayer.outputFormat(forBus: 0)
        guard let buffer = Self.audioBuffer(wav: wav, target: target) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scheduledBuffer = buffer
            playbackFinish = { continuation.resume() }
            playbackPlayer.scheduleBuffer(
                buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.scheduledBuffer = nil
                    self?.completePlayback()
                }
            }
            if !playbackPlayer.isPlaying { playbackPlayer.play() }
        }
    }

    func stopPlayback() {
        playbackPlayer.stop()
        completePlayback()
    }

    private func completePlayback() {
        playbackFinish?()
        playbackFinish = nil
    }

    /// Decode `wav` and convert it to the player node's output format, since
    /// `scheduleBuffer` requires an exact format match.
    private static func audioBuffer(wav: Data, target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idfon-parakeet-tts.wav")
        guard (try? wav.write(to: url)) != nil,
              let file = try? AVAudioFile(forReading: url),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil else { return nil }
        if file.processingFormat.sampleRate == target.sampleRate,
           file.processingFormat.channelCount == target.channelCount {
            return input
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        // One second of headroom so the converter's output buffer never fills.
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + AVAudioFrameCount(target.sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error else { return nil }
        return output
    }
}

/// Logs a download at most every 10% (the progress handler is hot).
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -10

    func shouldLog(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let percent = Int(fraction * 100)
        guard percent - lastPercent >= 10 || percent == 100 else { return false }
        lastPercent = percent
        return true
    }
}
