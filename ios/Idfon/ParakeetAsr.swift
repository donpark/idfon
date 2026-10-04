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
final class ParakeetReduxAsr: AsrEngine {
    let name = "parakeet-redux"

    private let engine = AVAudioEngine()
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
        warmLock.lock()
        if let task = warmTask {
            warmLock.unlock()
            await task.value
            return
        }
        let task = Task {
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
        warmTask = task
        warmLock.unlock()
        await task.value
        warmLock.lock()
        warmTask = nil  // allow a retry after a transient failure
        warmLock.unlock()
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

        let input = engine.inputNode
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
