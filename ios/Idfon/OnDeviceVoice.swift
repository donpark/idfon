import AVFAudio
import Foundation
import Speech

/// On-device TTS voice selection.
///
/// `AVSpeechSynthesisVoice(language:)` returns the *default* voice, which on a
/// stock device is the compact/robotic tier even when an enhanced/premium
/// neural voice for the same language is installed. Rank the installed voices
/// by quality and take the best available, unless a voice is requested
/// explicitly via `IDFON_TTS_VOICE` or `-ttsvoice <identifier|name-substring>`.
///
/// Enhanced/premium voices are user-downloaded (Settings > Accessibility >
/// Spoken Content > Voices), so ranking only helps once one is present; it
/// never regresses to a lower tier than the default.
enum SpeechVoice {
    static func best(language: String = "en-US") -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let exact = all.filter {
            $0.language == language || $0.language.hasPrefix(language + "-")
        }
        let base = String(language.split(separator: "-").first ?? "")
        let pool = exact.isEmpty ? all.filter { $0.language.hasPrefix(base) } : exact
        guard !pool.isEmpty else { return nil }
        if let request = requested() {
            if let hit = pool.first(where: { $0.identifier == request }) { return log(hit) }
            if let hit = pool
                .filter({ $0.name.localizedCaseInsensitiveContains(request) })
                .max(by: { rank($0) < rank($1) })
            { return log(hit) }
        }
        return pool
            .max(by: { rank($0) != rank($1) ? rank($0) < rank($1) : $0.name > $1.name })
            .map(log)
    }

    /// Higher is better: Siri ≈ Premium > Enhanced > default. `quality` is the
    /// base, but the identifier/name is checked too because some top tiers
    /// (notably Siri) do not reliably report as `premium`/`enhanced`.
    static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score: Int
        switch voice.quality {
        case .premium: score = 4000
        case .enhanced: score = 3000
        default: score = 1000
        }
        let label = (voice.identifier + " " + voice.name).lowercased()
        if label.contains("siri") || label.contains("premium") {
            score = max(score, 4000)
        } else if label.contains("enhanced") {
            score = max(score, 3000)
        }
        if #available(iOS 17.0, macOS 14.0, *) {
            if voice.voiceTraits.contains(.isNoveltyVoice) { score -= 800 }
            if voice.voiceTraits.contains(.isPersonalVoice) { score -= 400 }
        }
        return score
    }

    static func requested() -> String? {
        if let value = ProcessInfo.processInfo.environment["IDFON_TTS_VOICE"], !value.isEmpty {
            return value
        }
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-ttsvoice"), args.count > index + 1 {
            return args[index + 1]
        }
        return nil
    }

    @discardableResult
    static func log(_ voice: AVSpeechSynthesisVoice) -> AVSpeechSynthesisVoice {
        Automation.mark(
            "voice: tts voice=\(voice.name) quality=\(qualityName(voice)) id=\(voice.identifier)"
        )
        return voice
    }

    static func qualityName(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return "default"
        }
    }
}

/// Apple-native on-device voice provider (P6/A1): `AVSpeechSynthesizer` for TTS
/// and `SFSpeechRecognizer` with `requiresOnDeviceRecognition` for STT. No
/// network, no downloaded model beyond the OS speech assets.
///
/// The provider mirrors the Rust `idfon-voice` seam conceptually; this is the
/// client-side (A1) implementation that can run where memory allows.
final class OnDeviceVoice: NSObject {
    static let shared = OnDeviceVoice()

    private let queue = DispatchQueue(label: "app.idfon.ondevicevoice")
    /// Retained for the duration of a `write`; AVSpeechSynthesizer is async.
    private var synthesizer: AVSpeechSynthesizer?

    private final class SynthesisState {
        var file: AVAudioFile?
        var frames = 0
        var finished = false
    }

    enum VoiceError: LocalizedError {
        case synthesisFailed
        case recognizerUnavailable
        case onDeviceUnavailable
        case denied
        case recognitionTimedOut

        var errorDescription: String? {
            switch self {
            case .synthesisFailed: return "no audio synthesized"
            case .recognizerUnavailable: return "no en-US recognizer"
            case .onDeviceUnavailable: return "on-device recognition unavailable"
            case .denied: return "speech recognition not authorized"
            case .recognitionTimedOut: return "no speech recognized before timeout"
            }
        }
    }

    /// Synthesize `text` to a file entirely on device; reports the frame count.
    func synthesize(
        _ text: String,
        to url: URL,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        let state = SynthesisState()
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        try? FileManager.default.removeItem(at: url)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoice.best(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            self?.queue.async {
                if pcm.frameLength == 0 {
                    // A zero-length buffer ends synthesis.
                    guard !state.finished else { return }
                    state.finished = true
                    self?.synthesizer = nil
                    if state.frames > 0 {
                        completion(.success(state.frames))
                    } else {
                        completion(.failure(VoiceError.synthesisFailed))
                    }
                    return
                }
                if state.file == nil {
                    state.file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings)
                }
                guard let file = state.file else { return }
                do {
                    try file.write(from: pcm)
                    state.frames += Int(pcm.frameLength)
                } catch {
                    NSLog("idfon voice: tts write failed \(error.localizedDescription)")
                }
            }
        }
    }

    /// Transcribe an audio file with on-device recognition only.
    func transcribe(
        url: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                completion(.failure(VoiceError.denied))
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
                completion(.failure(VoiceError.recognizerUnavailable))
                return
            }
            guard recognizer.supportsOnDeviceRecognition else {
                completion(.failure(VoiceError.onDeviceUnavailable))
                return
            }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false

            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let error {
                    done = true
                    completion(.failure(error))
                    return
                }
                if let result, result.isFinal {
                    done = true
                    completion(.success(result.bestTranscription.formattedString))
                }
            }
        }
    }

    // MARK: - Live microphone → on-device STT

    private var audioEngine: AVAudioEngine?
    private var listenTask: SFSpeechRecognitionTask?
    private var listenRequest: SFSpeechAudioBufferRecognitionRequest?
    private var listenDone: ((Result<String, Error>) -> Void)?
    private var latestPartial = ""
    /// Retained during the barge-in exercise.
    var bargeInPlayer: AVAudioPlayer?
    /// iOS 26+ SpeechAnalyzer transcriber, retained while barge-in listens.
    var systemTranscriber: Any?

    func stopSystemTranscriber() {
        if #available(iOS 26.0, *), let transcriber = systemTranscriber as? SystemSpeechTranscriber {
            transcriber.stop()
        }
        systemTranscriber = nil
    }

    /// Start listening on the microphone and transcribe entirely on device.
    /// Partials are logged as they arrive; the first final result completes.
    func startListening(
        configureSession: Bool = true,
        enableVoiceProcessing: Bool = true,
        onPartial: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        AVAudioApplication.requestRecordPermission { granted in
            guard granted else {
                completion(.failure(VoiceError.denied))
                return
            }
            SFSpeechRecognizer.requestAuthorization { status in
                guard status == .authorized else {
                    completion(.failure(VoiceError.denied))
                    return
                }
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
                      recognizer.supportsOnDeviceRecognition
                else {
                    completion(.failure(VoiceError.onDeviceUnavailable))
                    return
                }

                if configureSession {
                    let session = AVAudioSession.sharedInstance()
                    try? session.setCategory(.record, mode: .measurement, options: [.duckOthers])
                    try? session.setActive(true, options: .notifyOthersOnDeactivation)
                }

                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true
                self.listenRequest = request
                self.listenDone = completion

                let engine = AVAudioEngine()
                let input = engine.inputNode
                // A caller-owned play-and-record session (barge-in) needs voice
                // processing for echo cancellation; query the format after
                // enabling it, since the input node reconfigures.
                // Voice processing needs an active output reference; in a
                // listen-only phase (no playback yet) it silences the mic, so
                // the caller can opt out.
                if !configureSession && enableVoiceProcessing {
                    try? input.setVoiceProcessingEnabled(true)
                }
                let format = input.outputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    request.append(buffer)
                }
                engine.prepare()
                do {
                    try engine.start()
                } catch {
                    completion(.failure(error))
                    return
                }
                self.audioEngine = engine

                self.listenTask = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.latestPartial = text
                        Automation.mark("voice: partial \(text)")
                        onPartial?(text)
                        if result.isFinal {
                            self.finishListening(.success(text))
                            return
                        }
                    }
                    if let error {
                        self.finishListening(.failure(error))
                    }
                }
            }
        }
    }

    /// Stop the microphone and recognition.
    func stopListening() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        listenRequest?.endAudio()
        listenRequest = nil
        listenTask?.cancel()
        listenTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func finishListening(_ result: Result<String, Error>) {
        let completion = listenDone
        listenDone = nil
        stopListening()
        completion?(result)
    }

    /// `-voicelisten`: wait for one on-device transcription of live speech. A
    /// recognizer that only produced partials by the deadline still counts as
    /// "heard" — the point is that the microphone reached on-device STT.
    func runListenSmokeTest(timeout: TimeInterval = 45) {
        latestPartial = ""
        Automation.mark("voice: listening")
        startListening { result in
            switch result {
            case .failure(let error):
                Automation.mark("voice: FAIL listen \(error.localizedDescription)")
            case .success(let text):
                Automation.mark("voice: heard transcript=\(text)")
                Automation.mark("voice: PASS")
            }
            Automation.mark("voice: done")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.listenDone != nil else { return }
            if self.latestPartial.isEmpty {
                self.finishListening(.failure(VoiceError.recognitionTimedOut))
            } else {
                self.finishListening(.success(self.latestPartial))
            }
        }
    }

    /// On-device round trip for `scripts/ios-voice-provider-test.sh`: TTS to a
    /// file, then on-device STT of that file. No microphone or network needed.
    func runSmokeTest() {
        let phrase = "the quick brown fox jumps over the lazy dog"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-voice-provider-test.wav")
        Automation.mark("voice: start")
        synthesize(phrase, to: url) { [weak self] result in
            switch result {
            case .failure(let error):
                Automation.mark("voice: FAIL tts \(error.localizedDescription)")
                Automation.mark("voice: done")
            case .success(let frames):
                Automation.mark("voice: tts frames=\(frames)")
                self?.transcribe(url: url) { result in
                    switch result {
                    case .failure(let error):
                        Automation.mark("voice: FAIL stt \(error.localizedDescription)")
                    case .success(let text):
                        Automation.mark("voice: stt transcript=\(text)")
                        let normalized = text.lowercased()
                        let ok = normalized.contains("quick brown fox")
                            || normalized.contains("the quick brown")
                        Automation.mark(ok ? "voice: PASS" : "voice: FAIL transcript mismatch")
                    }
                    Automation.mark("voice: done")
                }
            }
        }
    }
}
