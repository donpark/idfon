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
            // A full identifier resolves directly, even when `speechVoices()`
            // does not list it (a downloaded-but-unenumerated voice).
            if request.contains("."), let voice = AVSpeechSynthesisVoice(identifier: request) {
                return log(voice)
            }
            // An explicit identifier must win even if it names a compact voice.
            if let hit = pool.first(where: { $0.identifier == request }) { return log(hit) }
            if let hit = pool
                .filter({ $0.name.localizedCaseInsensitiveContains(request) })
                .max(by: { rank($0) < rank($1) })
            { return log(hit) }
        }
        // Auto-select: rank by quality tier, ignore novelty/personal voices,
        // and prefer the OS default when it is in the top tier.
        let eligible = pool.filter { !isNovelty($0) }
        let candidates = eligible.isEmpty ? pool : eligible
        let topScore = candidates.map(rank).max() ?? 0
        let top = candidates.filter { rank($0) == topScore }
        // Prefer the user's OS-default voice, then the same-named higher tier
        // (e.g. compact "Samantha" default → "Samantha (Enhanced)").
        if let systemDefault = AVSpeechSynthesisVoice(language: language) {
            if let exact = top.first(where: { $0.identifier == systemDefault.identifier }) {
                return log(exact)
            }
            if let sameName = top.first(where: { $0.name.hasPrefix(systemDefault.name) }) {
                return log(sameName)
            }
        }
        return top.min(by: { $0.name < $1.name }).map(log)
    }

    static func isCompact(_ voice: AVSpeechSynthesisVoice) -> Bool {
        (voice.identifier + " " + voice.name).lowercased().contains("compact")
    }

    /// Auto-selection score. `.quality` is authoritative (Apple: `.premium` >
    /// `.enhanced` > `.default`); the identifier only breaks ties toward the
    /// modern voice store. Do **not** key on names or a `siri` id: the
    /// "(Enhanced)" label is Settings UI, the Siri-section voices are not
    /// selectable by third-party apps, and `ttsbundle.siri_*_compact` is a
    /// legacy low-quality voice, not the Siri tier.
    static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        // `.quality` is the primary signal, but some neural voices reportedly
        // report `.default`; also accept an enhanced/premium identifier flag.
        // `siri` is deliberately not a tier: that section is not selectable by
        // third-party apps, and `ttsbundle.siri_*_compact` is legacy/low.
        let label = voice.identifier.lowercased()
        var score: Int
        if voice.quality == .premium || label.contains("premium") {
            score = 3000
        } else if voice.quality == .enhanced || label.contains("enhanced") {
            score = 2000
        } else {
            score = 1000
        }
        if voice.identifier.hasPrefix("com.apple.voice.") { score += 100 }
        if isNovelty(voice) { score -= 5000 }
        return score
    }

    /// Novelty/effect voices and the user's personal (cloned) voice are never
    /// chosen automatically; they are still available via an explicit override.
    static func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
        guard #available(iOS 17.0, macOS 14.0, *) else { return false }
        return voice.voiceTraits.contains(.isNoveltyVoice)
            || voice.voiceTraits.contains(.isPersonalVoice)
    }

    /// Log every installed voice for `language`, best-ranked first. Driven by
    /// the `-voices` launch arg so an operator can see what to pass to
    /// `-ttsvoice` / `IDFON_TTS_VOICE`.
    static func dump(language: String = "en-US") {
        let base = String(language.split(separator: "-").first ?? "")
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(base) }
            .sorted { rank($0) > rank($1) }
        Automation.mark("voice: voices language=\(language) count=\(voices.count) best-first")
        for voice in voices {
            Automation.mark(
                "voice:   rank=\(rank(voice)) quality=\(qualityName(voice))"
                    + "\(isCompact(voice) ? " compact" : "") \(voice.name) id=\(voice.identifier)"
            )
        }
        // Probe the modern voice-store tiers directly: `speechVoices()` only
        // lists downloaded voices, but an identifier may still resolve.
        Automation.mark("voice: current-language \(AVSpeechSynthesisVoice.currentLanguageCode())")
        for code in ["en", "en-US", "en-GB", "en-AU", "en-IE", "en-IN", "en-ZA", "en-NZ", "en-CA"] {
            let voice = AVSpeechSynthesisVoice(language: code)
            Automation.mark(
                "voice: default[\(code)] \(voice?.name ?? "nil")"
                    + " q=\(voice.map(qualityName) ?? "-")"
                    + " \(voice.map { isCompact($0) ? "compact" : "full" } ?? "-")"
                    + " id=\(voice?.identifier ?? "nil")"
            )
        }
        // No-reboot attempt: a downloaded-but-unenumerated voice may still
        // resolve by identifier, so probe a name×tier matrix and log hits.
        let names = [
            "Ava", "Zoe", "Evan", "Nathan", "Noelle", "Tom",
            "Samantha", "Nicky", "Aaron", "Allison", "Serena",
        ]
        let patterns = [
            "com.apple.voice.premium.en-US.%@",
            "com.apple.voice.enhanced.en-US.%@",
            "com.apple.ttsbundle.siri_%@_en-US_premium",
            "com.apple.ttsbundle.siri_%@_en-US_enhanced",
        ]
        var hits = 0
        for name in names {
            for pattern in patterns {
                let id = pattern.replacingOccurrences(of: "%@", with: name)
                if AVSpeechSynthesisVoice(identifier: id) != nil {
                    hits += 1
                    Automation.mark("voice: PROBE-HIT \(id)")
                }
            }
        }
        Automation.mark("voice: probe matrix hits=\(hits)")
        Automation.mark("voice: done")
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
        // VoiceOver's selected voice/rate must not override ours.
        utterance.prefersAssistiveTechnologySettings = false

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

    /// P5 text-layer echo rule over the C ABI: true when `heard` is the agent's
    /// own speech read back. Used to drop self-bleed in the voice-agent loop.
    func isEcho(spoken: String, heard: String) -> Bool {
        idfon_voice_is_echo(spoken, heard) != 0
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
