import AVFAudio
import AVFoundation
import Foundation
import Speech

/// Continuous on-device transcription for the mac barge-in path using the new
/// Speech framework (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26+). The
/// progressive preset emits volatile partial results live — legacy
/// `SFSpeechRecognizer` on macOS only finalizes.
///
/// Pattern borrowed from `~/dev/livesub` (SystemTranscriber): request assets,
/// prepare the analyzer for a fixed format, feed `AnalyzerInput` buffers from
/// an `AVAudioEngine` tap, consume `transcriber.results`.
@available(macOS 26.0, *)
final class MacSpeechTranscriber {
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var analyzerFormat: AVAudioFormat?
    private var lastPartial = ""
    private var fedFrames: AVAudioFramePosition = 0
    private var inputConverter: Any?
    /// True when VoiceProcessingIO is active; its multi-channel input format is
    /// fed via the manual converter rather than AnalyzerInputConverter.
    private var aecEnabled = false
    /// Tap gate. Pausing/restarting `AVAudioEngine` renegotiated IO while TTS
    /// played and could make `SpeechAnalyzer` reject the session; keeping the
    /// engine running and dropping tap buffers keeps the IO stable.
    private let gateLock = NSLock()
    private var listening = true

    init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    /// Start listening on the mic; `onText` receives (text, isFinal) as results
    /// stream, `onError` a failure description.
    func start(
        onText: @escaping (String, Bool) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        // Resolve the requested locale to a framework-supported `Locale` object:
        // constructing `Locale(identifier: "en-US")` can mismatch the form the
        // installed assets use ("en_US") and the transcriber rejects it.
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
        // livesub queries (and ignores) the best available format before
        // preparing the analyzer for a fixed 16 kHz mono Int16 format.
        _ = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [detector, transcriber])
        // livesub prepares the analyzer for a fixed 16 kHz mono Int16 format
        // and converts the mic tap into it.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        self.analyzerFormat = format
        // nil lets the analyzer pick the format its modules want; the
        // AnalyzerInputConverter is configured for the same modules.
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

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // macOS AEC is opt-in: enabling voice processing on the input node
        // hooks up the system VoiceProcessingIO (AEC + noise suppression).
        // The tap below therefore uses `format: nil` so it follows whatever
        // format the enabled node provides. It is off by default because some
        // devices (e.g. the LG UltraFine Display Audio USB mic) accept the call
        // but then deliver silence; set IDFON_MACOS_AEC=1 on a supported device.
        if ProcessInfo.processInfo.environment["IDFON_MACOS_AEC"] == "1" {
            do {
                try input.setVoiceProcessingEnabled(true)
                aecEnabled = true
                Automation.mark("voice: voice-processing enabled")
            } catch {
                Automation.mark("voice: voice-processing unsupported: \(error.localizedDescription)")
            }
        } else {
            Automation.mark("voice: voice-processing off (gated; set IDFON_MACOS_AEC=1 to enable)")
        }
        let hardware = input.outputFormat(forBus: 0)
        Automation.mark(
            "voice: analyzer rate=\(format.sampleRate) ch=\(format.channelCount) hw=\(hardware.sampleRate)/\(hardware.channelCount)"
        )
        // macOS 27 provides the official analyzer input converter, which turns
        // an arbitrary AVAudioEngine buffer into format-correct AnalyzerInputs.
        if #available(macOS 27.0, *), !aecEnabled {
            inputConverter = try await AnalyzerInputConverter.converter(
                compatibleWith: [detector, transcriber]
            )
            Automation.mark("voice: analyzer input converter ready")
        }
        var tapBuffers = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
            guard let self, let builder = self.inputBuilder else { return }
            guard self.isListening else { return }
            tapBuffers += 1
            if tapBuffers == 1 || tapBuffers % 500 == 0 {
                Automation.mark("voice: tap buffers=\(tapBuffers) frames=\(buffer.frameLength)")
            }
            if #available(macOS 27.0, *), !self.aecEnabled,
               let converter = self.inputConverter as? AnalyzerInputConverter {
                if let inputs = try? converter.convert(buffer, at: time) {
                    if tapBuffers <= 3 || tapBuffers % 200 == 0 {
                        Automation.mark("voice: analyzer inputs=\(inputs.count)")
                    }
                    for input in inputs { builder.yield(input) }
                } else if tapBuffers <= 3 {
                    Automation.mark("voice: analyzer convert nil")
                }
                return
            }
            // macOS 26 fallback: manual conversion + explicit timeline.
            if let converted = self.convert(buffer, to: format) {
                let start = CMTime(
                    value: self.fedFrames,
                    timescale: CMTimeScale(format.sampleRate)
                )
                self.fedFrames += AVAudioFramePosition(converted.frameLength)
                builder.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
            } else if tapBuffers <= 3 {
                Automation.mark("voice: convert nil")
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        resultsTask?.cancel()
        resultsTask = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        if #available(macOS 27.0, *),
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

    /// Close/open the tap gate without touching the engine or the analyzer, so
    /// the agent's own TTS cannot feed the next utterance.
    func pause() {
        setListening(false)
    }

    func resume() {
        setListening(true)
        // Recover if the engine was stopped (interruption/route change) while
        // gated; a normal resume does not restart it.
        guard let engine, !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
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

    /// Manual clocked conversion (48 kHz Float32 mono → 16 kHz Int16 mono),
    /// mirroring livesub's converter rather than trusting AVAudioConverter's
    /// buffer output for this pipeline.
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
