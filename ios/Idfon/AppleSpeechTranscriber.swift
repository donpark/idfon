import AVFAudio
import AVFoundation
import Foundation
import Speech

/// Continuous on-device transcription using the new Speech framework
/// (`SpeechAnalyzer` + `SpeechTranscriber`, iOS 26+). The progressive preset
/// emits volatile partial results live; below iOS 26 the app falls back to
/// `SFSpeechRecognizer` (`OnDeviceVoice.startListening`).
///
/// It is a *consumer* of the single microphone source (`AudioIO`): it owns no
/// `AVAudioEngine`, tap, or playback bus. Voice processing (AEC) is the
/// source's responsibility.
///
/// Counterpart of the macOS `MacSpeechTranscriber`; same options and pipeline.
@available(iOS 26.0, *)
final class AppleSpeechTranscriber: AudioCaptureObserver {
    private let locale: Locale
    /// Injected for tests; the app uses the single real microphone source.
    private let source: AudioSource
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var lastPartial = ""
    private var fedFrames: AVAudioFramePosition = 0
    private var inputConverter: Any?
    /// Tap gate. The source engine keeps running; this drops buffers while the
    /// agent thinks/speaks, so `SpeechAnalyzer` never sees the agent's own TTS.
    private let gateLock = NSLock()
    private var listening = true

    init(locale: Locale = Locale.current, source: AudioSource = AudioIO.shared) {
        self.locale = locale
        self.source = source
    }

    /// Start listening; `onText` receives (text, isFinal) as results stream,
    /// `onError` a failure description.
    func start(
        enableVoiceProcessing: Bool = true,
        onText: @escaping (String, Bool) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        // Resolve to a framework-supported `Locale`; a constructed identifier
        // can mismatch the installed asset form ("en_US" vs "en-US").
        let supported = await SpeechTranscriber.supportedLocales
        let installed = (await SpeechTranscriber.installedLocales).map(\.identifier).sorted()
        let chosen = supported.first { $0.identifier == locale.identifier }
            ?? supported.first { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
            ?? supported.first { $0.language.languageCode == locale.language.languageCode }
            ?? supported.first
            ?? locale
        Automation.mark(
            "voice: transcriber locale want=\(locale.identifier) chosen=\(chosen.identifier) installed=\(installed)"
        )

        // Explicit options: volatileResults is what streams live partials.
        let transcriber = SpeechTranscriber(
            locale: chosen,
            transcriptionOptions: [.etiquetteReplacements],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: false
        )

        _ = try await AssetInventory.assetInstallationRequest(supporting: [detector, transcriber])

        let analyzer = SpeechAnalyzer(modules: [detector, transcriber])
        self.analyzer = analyzer
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        self.analyzerFormat = format
        // nil lets the analyzer pick the format its modules want.
        try await analyzer.prepareToAnalyze(in: nil)

        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .unbounded
        )
        self.inputBuilder = builder
        try await analyzer.start(inputSequence: stream)
        Automation.mark("voice: analyzer started")

        self.resultsTask = Task {
            do {
                Automation.mark("voice: results loop start")
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    Automation.mark("voice: result final=\(result.isFinal) text=\(text.prefix(60))")
                    guard !text.isEmpty else { continue }
                    self.lastPartial = text
                    onText(text, result.isFinal)
                }
            } catch is CancellationError {
                return
            } catch {
                onError(error.localizedDescription)
            }
        }

        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        Automation.mark("voice: mic granted=\(granted)")

        if #available(iOS 27.0, *) {
            inputConverter = try await AnalyzerInputConverter.converter(
                compatibleWith: [detector, transcriber]
            )
            Automation.mark("voice: analyzer input converter ready")
        }
        // Capture is the single source's job; AEC is enabled there.
        source.addCaptureObserver(self)
        _ = enableVoiceProcessing
    }

    func stop() {
        source.removeCaptureObserver(self)
        resultsTask?.cancel()
        resultsTask = nil
        if #available(iOS 27.0, *),
           let converter = inputConverter as? AnalyzerInputConverter,
           let inputs = try? converter.flush() {
            for input in inputs { inputBuilder?.yield(input) }
        }
        inputConverter = nil
        inputBuilder?.finish()
        inputBuilder = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        Task { await analyzer?.cancelAndFinishNow() }
    }

    /// Close/open the buffer gate without touching the source or the analyzer,
    /// so the agent's own TTS cannot feed the next utterance.
    func pause() {
        setListening(false)
    }

    func resume() {
        setListening(true)
    }

    private func setListening(_ value: Bool) {
        gateLock.lock()
        listening = value
        gateLock.unlock()
    }

    private var isListening: Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        return listening
    }

    // MARK: - AudioCaptureObserver

    func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let builder = inputBuilder, isListening else { return }
        if #available(iOS 27.0, *),
           let converter = inputConverter as? AnalyzerInputConverter {
            if let inputs = try? converter.convert(buffer, at: time) {
                for input in inputs { builder.yield(input) }
            }
            return
        }
        // iOS 26 fallback: manual conversion + explicit timeline.
        guard let format = analyzerFormat, let converted = convert(buffer, to: format) else { return }
        let start = CMTime(
            value: fedFrames,
            timescale: CMTimeScale(format.sampleRate)
        )
        fedFrames += AVAudioFramePosition(converted.frameLength)
        builder.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
    }

    /// Manual conversion (tap format → 16 kHz Int16 mono) for iOS 26 before
    /// `AnalyzerInputConverter` existed.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let channels = buffer.floatChannelData, buffer.format.channelCount >= 1 else {
            return nil
        }
        let ratio = buffer.format.sampleRate / format.sampleRate
        let inputCount = Int(buffer.frameLength)
        let outputCount = Int(Double(inputCount) / ratio)
        guard outputCount > 0,
              let output = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(outputCount)
              ),
              let target = output.int16ChannelData?.pointee
        else { return nil }
        output.frameLength = AVAudioFrameCount(outputCount)
        let source = channels[0]
        for index in 0..<outputCount {
            let position = Double(index) * ratio
            let base = Int(position)
            let fraction = Float(position - Double(base))
            let a = source[min(base, inputCount - 1)]
            let b = source[min(base + 1, inputCount - 1)]
            let value = max(-1, min(1, a + (b - a) * fraction))
            target[index] = Int16(value * 32767)
        }
        return output
    }
}