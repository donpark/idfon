import AVFAudio
import Foundation
import FluidAudio

/// Parakeet Redux (moondream) recognizer via FluidAudio's
/// `SlidingWindowAsrManager` (macOS port of `ios/Idfon/ParakeetAsr.swift`).
///
/// Redux is a batch sliding-window model, but the manager exposes it as a
/// stream: we push mic buffers and it emits volatile/confirmed
/// `transcriptionUpdates`, which map onto the loop's partial/final model.
@available(macOS 15.0, *)
final class ParakeetReduxAsr: AsrEngine, AudioCaptureObserver {
    let name = "parakeet-redux"

    private let gateLock = NSLock()
    private var gated = false
    private var manager: SlidingWindowAsrManager?
    private var feedTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var onText: ((String, Bool) -> Void)?
    private var onSamples: (([Float], Double) -> Void)?
    private var started = false

    // Single-flight warm task: download + CoreML-compile ahead of the first
    // turn so `start` doesn't pay for it. The loaded instance is dropped;
    // FluidAudio reuses the compiled artifacts on disk.
    private static let warmLock = NSLock()
    private static var warmTask: Task<Void, Never>?

    func prepare() async { await Self.warmCache() }

    /// `~/.idfon/models/<parakeet repo>`, migrating FluidAudio's old
    /// `~/Library/Application Support/FluidAudio/Models` copy on first use.
    static func modelDirectory() -> URL {
        let legacy = AsrModels.defaultCacheDirectory(for: .redux)
        let directory = ModelStore.directory(named: legacy.lastPathComponent)
        if let moved = ModelStore.migrate(from: legacy, to: directory) {
            Automation.mark("voice: parakeet models migrated -> \(moved.path)")
        }
        return directory
    }

    static func warmCache() async {
        let task = warmLock.withLock { () -> Task<Void, Never> in
            if let existing = warmTask { return existing }
            let created = Task {
                guard VoiceModelGate.approved else {
                    Automation.mark("voice: parakeet prewarm skipped (no download approval)")
                    return
                }
                let throttle = ProgressThrottle()
                Automation.mark("voice: parakeet prewarming")
                do {
                    _ = try await AsrModels.downloadAndLoad(to: Self.modelDirectory(), version: .redux) { progress in
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
        let models = try await AsrModels.downloadAndLoad(to: Self.modelDirectory(), version: .redux) { progress in
            if throttle.shouldLog(progress.fractionCompleted) {
                Automation.mark("voice: parakeet download \(Int(progress.fractionCompleted * 100))%")
            }
        }
        let manager = SlidingWindowAsrManager()
        try await manager.loadModels(models)
        try await manager.startStreaming(source: .microphone)
        self.manager = manager

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

        // The shared VPIO tap (single input owner): subscribe instead of
        // running a private AVAudioEngine (docs/audio-media.md).
        AudioMeter.addCaptureObserver(self)
        started = true
        Automation.mark("voice: parakeet ready")
        _ = onError
    }

    /// The shared mic stream (AudioCaptureObserver).
    func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        // Side analysis (the turn-taker) sees everything, gate or not —
        // barge detection runs exactly while the gate is down.
        if let onSamples = onSamples {
            onSamples(Self.monoSamples(buffer), buffer.format.sampleRate)
        }
        guard !isGated else { return }
        bufferContinuation?.yield(buffer)
    }

    func pause() { setGated(true) }

    func setSamplesHandler(_ handler: (([Float], Double) -> Void)?) {
        onSamples = handler
    }

    /// Channel-0 f32 samples of a tap buffer (Float32 format at the input).
    private static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
    }

    func resume() {
        setGated(false)
    }

    func stop() {
        guard started || manager != nil else { return }
        started = false
        updatesTask?.cancel()
        updatesTask = nil
        feedTask?.cancel()
        feedTask = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        AudioMeter.removeCaptureObserver(self)
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
