import AVFAudio
import Foundation
import FluidAudio

/// Nemotron 3.5 streaming 0.6B recognizer — the call ASR (2026-10-25 ruling:
/// the duplex loop needs streaming input, which Parakeet Redux lacks; "swap,
/// not add"). FluidAudio's streaming Nemotron manager runs the true
/// streaming pipeline (encoder cache states, native mel front-end); mic
/// buffers arrive through the shared capture tap and text leaves as partials
/// (macOS port of `ios/Idfon/NemotronStreamingAsr.swift`).
///
/// Runs one of two bundles, picked at build time: the English ship
/// (`nemotron-speech-streaming-en-0.6b-coreml/560ms`, 597 MiB) **by default**,
/// or — with `IDFON_ASR_MULTILINGUAL=1` — the licence-matched 3.5 multilingual
/// bundle's pruned `latin/560ms` tier (583 MiB), driven as English. The
/// multilingual bundle is OpenMDW-1.1 like the TYGER 3.5 tiers we ship; the
/// English bundle is NVIDIA's Open Model License (mixing grants). See the
/// bundle swap measurement in `docs/voice-tyger-ondevice.md`.
///
/// Turn boundaries belong to the segmenter, but the manager's transcript
/// accumulates across the whole stream — so every commit (and every barge
/// clear) resets it via `utteranceCommitted()`, keeping `onText` = the
/// current utterance only.
@available(macOS 15.0, *)
final class NemotronStreamingAsr: AsrEngine, AudioCaptureObserver {
    let name = "nemotron-streaming"

    /// Two bundles, one build:
    /// - default: the English `nemotron-speech-streaming-en-0.6b-coreml/560ms`
    ///   ship (597 MiB, NVIDIA Open Model License).
    /// - `IDFON_ASR_MULTILINGUAL=1`: the 3.5 multilingual bundle's pruned
    ///   `latin/560ms` tier (583 MiB, OpenMDW-1.1 like the TYGER tiers),
    ///   driven as English. The full-vocab `multilingual/560ms` tier would
    ///   cost +36 MiB.
    #if NEMOTRON_MULTILINGUAL
    static let repo = Repo.nemotronMultilingual
    static let languageCode = "en-US"
    static var variantSubdirectory: String { "latin/\(chunkMs)ms" }
    /// Both managers expose the same load/process/reset contract.
    private typealias Manager = StreamingNemotronMultilingualAsrManager
    #else
    static let repo = Repo.nemotronStreaming560
    private typealias Manager = StreamingNemotronAsrManager
    #endif
    static let chunkMs = 560

    private let gateLock = NSLock()
    private var gated = false
    private var manager: Manager?
    private var feedTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<(Int, AVAudioPCMBuffer)>.Continuation?
    /// Bumped at every utterance commit: the feed drops buffers captured
    /// under an older epoch instead of transcribing them into the next
    /// utterance. Read from the audio thread — a plain Int bump/race is
    /// benign here (worst case one buffer lands on the wrong side).
    private var epoch = 0
    private var onText: ((String, Bool) -> Void)?
    private var onError: ((String) -> Void)?
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
        let base = ModelStore.directory(named: repo.folderName)
        #if NEMOTRON_MULTILINGUAL
        return base.appendingPathComponent(variantSubdirectory, isDirectory: true)
        #else
        return base
        #endif
    }

    /// Fetch the selected bundle: the English `560ms` dir whole, or only the
    /// `latin/<tier>ms` variant (`.mlmodelc`, no `.mlpackage` sources).
    static func download(chunkMs: Int) async throws {
        #if NEMOTRON_MULTILINGUAL
        _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: languageCode, chunkMs: chunkMs, to: ModelStore.root)
        #else
        try await ModelHub.download(repo, to: ModelStore.root)
        #endif
    }

    static func warmCache() async {
        let task = warmLock.withLock { () -> Task<Void, Never> in
            if let existing = warmTask { return existing }
            let created = Task {
                guard VoiceModelGate.approved else {
                    Automation.mark("voice: nemotron prewarm skipped (no download approval)")
                    return
                }
                Automation.mark("voice: nemotron prewarming")
                do {
                    try await download(chunkMs: chunkMs)
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
        self.onError = onError
        Automation.mark("voice: nemotron initializing")
        // Downloads are the approval gate's job (2026-10-27 rule): a call
        // loads from disk and fails clearly if the models are not there.
        if VoiceModelGate.approved {
            try await Self.download(chunkMs: Self.chunkMs)
        }
        let manager = Manager()
        try await manager.loadModels(from: Self.modelDirectory())
        #if NEMOTRON_MULTILINGUAL
        await manager.setLanguage(Self.languageCode)
        #endif
        await manager.setPartialCallback { [weak self] text in
            // The manager calls back from its actor; the session marshals to
            // the main thread itself, like every other ASR backend.
            self?.onText?(text, false)
        }
        self.manager = manager
        startFeed(manager)

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
        bufferContinuation?.yield((epoch, buffer))
    }

    func pause() { setGated(true) }

    func resume() { setGated(false) }

    func setSamplesHandler(_ handler: (([Float], Double) -> Void)?) {
        onSamples = handler
    }

    /// A turn committed (or a barge cleared the utterance): drop the running
    /// transcript so the next partial is the next utterance only. Buffers
    /// captured before the commit are dropped by the feed's epoch check —
    /// chunked inference can lag real time, and stale audio re-transcribes
    /// consumed words into the fresh transcript (the cross-turn accumulation
    /// bug). The stream lives for the whole session; only its content is
    /// fenced — restarting the feed proved fragile.
    func utteranceCommitted() {
        guard started, let manager else { return }
        epoch &+= 1
        Automation.mark("voice: nemotron utterance committed epoch=\(epoch)")
        Task { await manager.reset() }
    }

    /// The mic→manager feed, one stream per session. Bounded: under overload
    /// the oldest audio drops instead of the stream lagging behind real time
    /// without bound.
    /// no guard here — called once from `start` (before `started` is set);
    /// the epoch fence and `stop()` own the lifecycle.
    private func startFeed(_ manager: Manager) {
        let (stream, continuation) = AsyncStream<(Int, AVAudioPCMBuffer)>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        bufferContinuation = continuation
        feedTask = Task { [weak self] in
            for await (capturedEpoch, buffer) in stream {
                if Task.isCancelled { break }
                guard let self else { return }
                guard self.epoch == capturedEpoch else { continue }
                do {
                    _ = try await manager.process(audioBuffer: buffer)
                } catch {
                    Automation.mark("voice: nemotron error \(error.localizedDescription)")
                    self.onError?("nemotron: \(error.localizedDescription)")
                }
            }
        }
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
        onError = nil
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
