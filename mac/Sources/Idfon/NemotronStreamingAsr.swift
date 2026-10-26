import AVFAudio
import Foundation
import FluidAudio

/// Nemotron Speech Streaming 0.6B recognizer — the call ASR (2026-10-25
/// ruling: the duplex loop needs streaming input, which Parakeet Redux lacks;
/// "swap, not add"). FluidAudio's `StreamingNemotronAsrManager` runs the true
/// streaming pipeline (encoder cache states, native mel front-end); mic
/// buffers arrive through the shared capture tap and text leaves as partials
/// (macOS port of `ios/Idfon/NemotronStreamingAsr.swift`).
///
/// Turn boundaries belong to the segmenter, but the manager's transcript
/// accumulates across the whole stream — so every commit (and every barge
/// clear) resets it via `utteranceCommitted()`, keeping `onText` = the
/// current utterance only.
@available(macOS 15.0, *)
final class NemotronStreamingAsr: AsrEngine, AudioCaptureObserver {
    let name = "nemotron-streaming"

    /// The 560 ms chunk tier: the lowest-latency variant of the three shipped
    /// (`FluidInference/nemotron-speech-streaming-en-0.6b-coreml/560ms`).
    static let repo = Repo.nemotronStreaming560

    private let gateLock = NSLock()
    private var gated = false
    private var manager: StreamingNemotronAsrManager?
    private var feedTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var onText: ((String, Bool) -> Void)?
    private var onSamples: (([Float], Double) -> Void)?
    private var started = false

    // Single-flight warm task: download + CoreML-compile ahead of the first
    // turn so `start` doesn't pay for it.
    private static let warmLock = NSLock()
    private static var warmTask: Task<Void, Never>?

    func prepare() async { await Self.warmCache() }

    /// `~/.idfon/models/<nemotron repo folder>`, the ModelStore convention —
    /// exactly where `ModelHub.download` lands the files (it appends the
    /// repo's folder name under `to:` itself).
    static func modelDirectory() -> URL {
        ModelStore.directory(named: repo.folderName)
    }

    static func warmCache() async {
        let task = warmLock.withLock { () -> Task<Void, Never> in
            if let existing = warmTask { return existing }
            let created = Task {
                Automation.mark("voice: nemotron prewarming")
                do {
                    try await ModelHub.download(repo, to: ModelStore.root)
                    Automation.mark("voice: nemotron prewarmed")
                } catch {
                    Automation.mark("voice: nemotron prewarm failed \(error.localizedDescription)")
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
        Automation.mark("voice: nemotron initializing")
        try await ModelHub.download(Self.repo, to: ModelStore.root)
        let manager = StreamingNemotronAsrManager()
        try await manager.loadModels(from: Self.modelDirectory())
        await manager.setPartialCallback { [weak self] text in
            // The manager calls back from its actor; the session marshals to
            // the main thread itself, like every other ASR backend.
            self?.onText?(text, false)
        }
        self.manager = manager

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .unbounded
        )
        bufferContinuation = continuation
        feedTask = Task {
            for await buffer in stream {
                if Task.isCancelled { break }
                do {
                    _ = try await manager.process(audioBuffer: buffer)
                } catch {
                    Automation.mark("voice: nemotron error \(error.localizedDescription)")
                    onError("nemotron: \(error.localizedDescription)")
                }
            }
        }

        // The shared VPIO tap (single input owner): subscribe instead of
        // running a private AVAudioEngine (docs/audio-media.md).
        AudioMeter.addCaptureObserver(self)
        started = true
        Automation.mark("voice: nemotron ready")
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

    func resume() { setGated(false) }

    func setSamplesHandler(_ handler: (([Float], Double) -> Void)?) {
        onSamples = handler
    }

    /// A turn committed (or a barge cleared the utterance): drop the running
    /// transcript so the next partial is the next utterance only.
    func utteranceCommitted() {
        let manager = self.manager
        Task { await manager?.reset() }
    }

    func stop() {
        guard started || manager != nil else { return }
        started = false
        feedTask?.cancel()
        feedTask = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        AudioMeter.removeCaptureObserver(self)
        let manager = self.manager
        self.manager = nil
        Task { await manager?.cleanup() }
        onText = nil
    }

    private var isGated: Bool { gateLock.withLock { gated } }

    private func setGated(_ value: Bool) {
        gateLock.withLock { gated = value }
    }

    /// Channel-0 f32 samples of a tap buffer (Float32 format at the input).
    private static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
    }
}
