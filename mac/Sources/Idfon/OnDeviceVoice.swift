import AVFAudio
import AVFoundation
import CIdfon
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
/// Enhanced/premium voices are user-downloaded (System Settings > Accessibility
/// > Spoken Content > System Voice > Manage Voices), so ranking only helps once
/// one is present; it never regresses to a lower tier than the default.
enum SpeechVoice {
    /// BCP-47 tag of the system's preferred language, for built-in voice
    /// selection when an on-device neural engine is unavailable/unsupported.
    static var callLanguage: String { Locale.preferredLanguages.first ?? "en-US" }

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

/// Apple-native on-device voice provider for macOS (P6/A1): `AVSpeechSynthesizer`
/// for TTS and `SFSpeechRecognizer` with `requiresOnDeviceRecognition` for STT.
///
/// P5 barge-in: `runBargeInExercise` plays a synthesized answer while the mic
/// listens with voice processing (AEC) enabled, and engages on the first
/// cancellable, non-echo partial. The barge-in/echo rules come from Rust over
/// the CIdfon C ABI (`idfon_voice_is_cancellable` / `idfon_voice_is_echo`).
final class OnDeviceVoice: NSObject {
    static let shared = OnDeviceVoice()

    private let queue = DispatchQueue(label: "app.idfon.mac.ondevicevoice")
    private var synthesizer: AVSpeechSynthesizer?
    private var audioEngine: AVAudioEngine?
    private var listenTask: SFSpeechRecognitionTask?
    private var listenRequest: SFSpeechAudioBufferRecognitionRequest?
    private var listenDone: ((Result<String, Error>) -> Void)?
    private var latestPartial = ""
    var bargeInPlayer: AVAudioPlayer?
    private var macTranscriber: Any?

    private func stopMacTranscriber() {
        if #available(macOS 26.0, *), let transcriber = macTranscriber as? MacSpeechTranscriber {
            transcriber.stop()
        }
        macTranscriber = nil
    }

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
            case .denied: return "microphone or speech recognition not authorized"
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
        utterance.voice = SpeechVoice.best(language: SpeechVoice.callLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // VoiceOver's selected voice/rate must not override ours.
        utterance.prefersAssistiveTechnologySettings = false

        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            self?.queue.async {
                if pcm.frameLength == 0 {
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
                    idfonError("idfon voice: tts write failed \(error.localizedDescription)")
                }
            }
        }
    }

    /// Blocking wrapper: synthesize and convert to s16 mono PCM.
    func synthesizePCM(_ text: String) -> (rate: UInt32, data: Data)? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-mac-ffi-tts.wav")
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        let start = {
            self.synthesize(text, to: url) { result in
                if case .success = result { ok = true }
                semaphore.signal()
            }
        }
        if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
        guard semaphore.wait(timeout: .now() + 30) == .success, ok else { return nil }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = max(1, Int(format.channelCount))
        var data = Data(capacity: count * 2)
        for frame in 0..<count {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            let value = max(-1, min(1, sum / Float(channelCount)))
            var sample = Int16(value * 32767).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return (UInt32(format.sampleRate.rounded()), data)
    }

    /// Transcribe a buffer of 16-bit mono PCM with on-device recognition.
    func transcribePCM(_ data: Data, sampleRate: UInt32) -> String? {
        guard let wav = Self.pcmWav(data, sampleRate: sampleRate) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-listening-stt.wav")
        guard (try? wav.write(to: url)) != nil else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var transcript: String?
        let start = {
            SFSpeechRecognizer.requestAuthorization { status in
                guard status == .authorized,
                      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
                else {
                    semaphore.signal()
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.requiresOnDeviceRecognition = true
                var finished = false
                recognizer.recognitionTask(with: request) { result, error in
                    guard !finished else { return }
                    if let result, result.isFinal {
                        finished = true
                        transcript = result.bestTranscription.formattedString
                        semaphore.signal()
                    } else if error != nil {
                        finished = true
                        semaphore.signal()
                    }
                }
            }
        }
        if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
        guard semaphore.wait(timeout: .now() + 30) == .success else { return nil }
        return transcript
    }

    /// Minimal 16-bit mono RIFF/WAVE wrapper.
    static func pcmWav(_ pcm: Data, sampleRate: UInt32) -> Data? {
        guard pcm.count % 2 == 0 else { return nil }
        var wav = Data(capacity: 44 + pcm.count)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        let dataLen = UInt32(pcm.count)
        wav.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataLen)
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(16)
        append16(1)
        append16(1)
        append(sampleRate)
        append(sampleRate * 2)
        append16(2)
        append16(16)
        wav.append(contentsOf: Array("data".utf8))
        append(dataLen)
        wav.append(pcm)
        return wav
    }

    /// Start listening on the microphone and transcribe entirely on device.
    func startListening(
        enableVoiceProcessing: Bool = false,
        onPartial: ((String) -> Void)? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        Automation.mark("voice: listen start")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Automation.mark("voice: mic granted=\(granted)")
            guard granted else {
                completion(.failure(VoiceError.denied))
                return
            }
            SFSpeechRecognizer.requestAuthorization { status in
                Automation.mark("voice: speech auth=\(status.rawValue)")
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

                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true
                self.listenRequest = request
                self.listenDone = completion

                let engine = AVAudioEngine()
                let input = engine.inputNode
                if enableVoiceProcessing {
                    do {
                        try input.setVoiceProcessingEnabled(true)
                        Automation.mark("voice: voice-processing enabled")
                    } catch {
                        Automation.mark("voice: voice-processing FAIL \(error.localizedDescription)")
                    }
                }
                let format = input.outputFormat(forBus: 0)
                Automation.mark("voice: input rate=\(format.sampleRate) ch=\(format.channelCount)")
                var tapBuffers = 0
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    tapBuffers += 1
                    if tapBuffers == 1 || tapBuffers % 500 == 0 {
                        Automation.mark("voice: tap buffers=\(tapBuffers) frames=\(buffer.frameLength)")
                    }
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

    func stopListening() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        listenRequest?.endAudio()
        listenRequest = nil
        listenTask?.cancel()
        listenTask = nil
    }

    /// P5 text-layer echo rule over the C ABI: true when `heard` is the agent's
    /// own speech read back. Used to drop self-bleed in the voice-agent loop.
    func isEcho(spoken: String, heard: String) -> Bool {
        idfon_voice_is_echo(spoken, heard) != 0
    }

    /// P5 barge-in rule over the C ABI: whether a committed utterance may
    /// cancel the agent's playback (backchannels/sub-minimum never do).
    func isCancellable(_ text: String, inToolWindow: Bool = false) -> Bool {
        idfon_voice_is_cancellable(text, 1, inToolWindow ? 1 : 0) != 0
    }

    func finishListening(_ result: Result<String, Error>) {
        let completion = listenDone
        listenDone = nil
        stopListening()
        completion?(result)
    }

    /// `-voicelistening` (P7): synthesize a phrase set and transcribe it back
    /// on device, emitting `ref=/hyp=` pairs the harness scores for WER.
    func runListeningTest() {
        // Plain-word phrases: digits and ambiguous compounds are format noise
        // the recognizer normalizes, not intelligibility failures.
        let phrases = [
            "the quick brown fox jumps over the lazy dog",
            "the cat sat quietly on the mat by the fire",
            "please bring the blue folder to the meeting room",
            "we should leave before the traffic gets bad",
            "the river runs through the valley toward the sea",
        ]
        var done = 0
        for phrase in phrases {
            guard let pcm = synthesizePCM(phrase),
                  let transcript = transcribePCM(pcm.data, sampleRate: pcm.rate)
            else {
                Automation.mark("voice: listening pair ref=\(phrase) hyp=FAILED")
                continue
            }
            Automation.mark("voice: listening pair ref=\(phrase) hyp=\(transcript)")
            done += 1
        }
        Automation.mark("voice: listening done count=\(done) of \(phrases.count)")
    }

    /// `-bargein`: play a synthesized answer while the mic listens with voice
    /// processing (AEC); the first cancellable, non-echo partial engages.
    func runBargeInExercise(timeout: TimeInterval = 40) {
        Automation.mark("voice: bargein start")
        let phrase = "Here is a longer answer that keeps talking for a while so "
            + "you have time to interrupt me by speaking over the top of it. "
            + "I will keep going and going and going so please just start "
            + "talking whenever you are ready and it will stop."
        guard let pcm = synthesizePCM(phrase),
              let wav = Self.pcmWav(pcm.data, sampleRate: pcm.rate)
        else {
            Automation.mark("voice: FAIL bargein synth")
            Automation.mark("voice: done")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-mac-bargein.wav")
        guard (try? wav.write(to: url)) != nil,
              let player = try? AVAudioPlayer(contentsOf: url)
        else {
            Automation.mark("voice: FAIL bargein player")
            Automation.mark("voice: done")
            return
        }
        bargeInPlayer = player
        Automation.mark("voice: bargein prepared seconds=\(player.duration)")

        let handle: (String) -> Void = { [weak self] text in
            guard let self, player.isPlaying else { return }
            let cancellable = idfon_voice_is_cancellable(text, 1, 0) != 0
            let echo = idfon_voice_is_echo(phrase, text) != 0
            if cancellable && !echo {
                player.stop()
                self.bargeInPlayer = nil
                self.stopMacTranscriber()
                Automation.mark("voice: bargein engaged transcript=\(text)")
                Automation.mark("voice: PASS")
                Automation.mark("voice: done")
                self.finishListening(.success(text))
            } else {
                Automation.mark("voice: bargein ignored echo=\(echo) text=\(text)")
            }
        }

        // macOS 26+ uses the progressive SpeechAnalyzer for live partials;
        // legacy SFSpeechRecognizer on macOS only finalizes.
        if #available(macOS 26.0, *) {
            let transcriber = MacSpeechTranscriber()
            macTranscriber = transcriber
            var attempts = 0
            func startAnalyzer() {
                attempts += 1
                Task {
                    do {
                        try await transcriber.start(
                            onText: { text, _ in handle(text) },
                            onError: { message in
                                // livesub recovers from transient RecogRejected
                                // by resetting; retry a bounded number of times.
                                Automation.mark("voice: analyzer error attempt=\(attempts) \(message)")
                                transcriber.stop()
                                if attempts < 3, player.isPlaying {
                                    startAnalyzer()
                                } else {
                                    Automation.mark("voice: FAIL bargein listen \(message)")
                                    Automation.mark("voice: done")
                                }
                            }
                        )
                    } catch {
                        Automation.mark("voice: FAIL bargein listen \(error.localizedDescription)")
                        Automation.mark("voice: done")
                    }
                }
            }
            startAnalyzer()
        } else {
            startListening(enableVoiceProcessing: true, onPartial: handle) { result in
                if case .failure(let error) = result {
                    Automation.mark("voice: FAIL bargein listen \(error.localizedDescription)")
                    Automation.mark("voice: done")
                }
            }
        }

        Automation.mark("voice: SPEAK NOW in 2s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            player.play()
            Automation.mark("voice: bargein playing")
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 1) { [weak self] in
                guard let self, let current = self.bargeInPlayer, !current.isPlaying else { return }
                self.bargeInPlayer = nil
                self.stopMacTranscriber()
                Automation.mark("voice: FAIL bargein no interruption")
                Automation.mark("voice: done")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.bargeInPlayer != nil else { return }
            self.bargeInPlayer = nil
            self.stopMacTranscriber()
            Automation.mark("voice: FAIL bargein no interruption")
            Automation.mark("voice: done")
        }
    }
}
