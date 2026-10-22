import AVFAudio
import Foundation
import FluidAudio

/// Reply-speech backend for the on-device voice loop (macOS port of
/// `ios/Idfon/SpeechEngine.swift`).
///
/// Kokoro (FluidAudio, ANE) is the default for English and Apple's
/// `AVSpeechSynthesizer` is the default for every other system language (and
/// the offline fallback, and the explicit alternative). Selection:
/// `IDFON_TTS=kokoro|pocket|apple` (env) or `-ttsbackend <name>` (launch arg).
/// `pocket` is the Pocket TTS trial (voice cloning; `IDFON_TTS_VOICE`,
/// `IDFON_TTS_CLONE` — see `PocketTtsEngine`).
@MainActor
protocol TtsEngine: AnyObject {
    var name: String { get }
    /// Wall time of the last `speak`, in ms (nil when not measured).
    var lastLatencyMs: Int? { get }
    /// Download/load models if needed (no-op for Apple).
    func prepare() async
    /// Speak `text`, returning when playback finishes.
    func speak(_ text: String) async
    func stop()
}

extension TtsEngine {
    var lastLatencyMs: Int? { nil }
}

/// Reply-speech backend choice, persisted across launches.
enum TtsBackend: String, CaseIterable {
    case kokoro
    case pocket
    case apple

    var title: String {
        switch self {
        case .kokoro: return "Kokoro (on-device)"
        case .pocket: return "Pocket TTS (on-device)"
        case .apple: return "Apple Built-in"
        }
    }
}

/// On-device recognizer behind the voice loop.
protocol AsrEngine: AnyObject {
    var name: String { get }
    /// Pure transcription time for the last final, in ms (nil when the engine
    /// streams without a discrete compute step).
    var lastLatencyMs: Int? { get }
    /// Download/compile models ahead of the first turn (no-op for streaming
    /// system recognizers). Called by `SpeechEngines.prewarm()`.
    func prepare() async
    func start(
        enableVoiceProcessing: Bool,
        onText: @escaping (String, Bool) -> Void,
        onError: @escaping (String) -> Void
    ) async throws
    func pause()
    func resume()
    func stop()
    /// Raw capture samples (mono f32 at the input device's rate) for side
    /// analysis — the turn-taker's user channel. Fires even while gated
    /// (barge detection needs the mic during playback).
    func setSamplesHandler(_ handler: (([Float], Double) -> Void)?)
}

extension AsrEngine {
    var lastLatencyMs: Int? { nil }
    func prepare() async {}
    func setSamplesHandler(_ handler: (([Float], Double) -> Void)?) {}
    /// Whether recent input loudness is enough to count as barge-in on a
    /// no-AEC platform (macOS gated mode). Defaults to true (AEC platforms).
    var bargeInEngages: Bool { true }
}

enum AsrBackend: String, CaseIterable {
    case system
    case parakeet

    var title: String {
        switch self {
        case .system: return "Apple Built-in"
        case .parakeet: return "Parakeet Redux (on-device)"
        }
    }
}

/// The on-device neural engines are English-only: Parakeet Redux and the
/// Kokoro ANE pipeline are built with English weights and a text frontend.
/// Other system languages get the Apple built-ins, which follow the system
/// locale. (Kokoro's zh/ja/es/fr ANE variants exist in FluidAudio but are not
/// wired up here.)
///
/// Assumes the spoken language matches the system language; a caller who
/// wants to override can pick an engine explicitly per contact in Contact
/// Detail.
enum OnDeviceSpeechLanguage {
    static var isEnglish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("en") ?? true
    }
}

@MainActor
enum SpeechEngines {
    /// The active engine; read by `VoiceAgentSession` at call time.
    static var tts: TtsEngine = makeTts(ttsBackend)

    /// System-language default; `IDFON_TTS`/`-ttsbackend` override.
    /// Per-contact picks live in Contact Detail.
    static var ttsBackend: TtsBackend {
        if let override = overrideTts() { return override }
        return OnDeviceSpeechLanguage.isEnglish ? .kokoro : .apple
    }

    /// Warm the selected engine so the first call's reply is not blocked by a
    /// cold model download/compile.
    static func prewarm() {
        Task { await tts.prepare() }
        if asrBackend == .parakeet {
            Task {
                if #available(macOS 15.0, *) { await ParakeetReduxAsr.warmCache() }
            }
        }
    }

    /// System-language default; `IDFON_ASR`/`-asrbackend` override.
    /// Per-contact picks live in Contact Detail.
    static var asrBackend: AsrBackend {
        let override = ProcessInfo.processInfo.environment["IDFON_ASR"] ?? asrLaunchArg()
        if let override, !override.isEmpty {
            return AsrBackend(rawValue: override.lowercased()) ?? .system
        }
        return OnDeviceSpeechLanguage.isEnglish ? .parakeet : .system
    }

    /// The configured recognizer, or nil to use the SFSpeech fallback (system
    /// backend on macOS < 26).
    static func makeAsr() -> (any AsrEngine)? { makeAsr(asrBackend) }

    /// Build a recognizer for `backend`, independent of the persisted global
    /// choice (per-contact on-device selection).
    static func makeAsr(_ backend: AsrBackend) -> (any AsrEngine)? {
        switch backend {
        case .parakeet:
            guard #available(macOS 15.0, *) else { return nil }
            Automation.mark("voice: asr backend=parakeet")
            return ParakeetReduxAsr()
        case .system:
            if #available(macOS 26.0, *) {
                Automation.mark("voice: asr backend=system")
                return MacSystemAsr()
            }
            return nil
        }
    }

    /// Build a reply-voice engine for `backend`, independent of the persisted
    /// global choice (per-contact on-device selection).
    static func makeTts(_ backend: TtsBackend) -> TtsEngine {
        Automation.mark("voice: tts backend=\(backend.rawValue)")
        switch backend {
        case .apple: return AppleTtsEngine()
        case .kokoro: return KokoroTtsEngine()
        case .pocket: return PocketTtsEngine()
        }
    }

    private static func overrideTts() -> TtsBackend? {
        let value = ProcessInfo.processInfo.environment["IDFON_TTS"] ?? ttsLaunchArg()
        guard let value, !value.isEmpty else { return nil }
        return TtsBackend(rawValue: value.lowercased())
    }

    private static func ttsLaunchArg() -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-ttsbackend"), args.count > index + 1 {
            return args[index + 1]
        }
        return nil
    }

    private static func asrLaunchArg() -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-asrbackend"), args.count > index + 1 {
            return args[index + 1]
        }
        return nil
    }
}

/// Apple system voice. Honors `SpeechVoice.best` and ignores VoiceOver's
/// assistive-technology voice override.
@MainActor
final class AppleTtsEngine: NSObject, TtsEngine {
    let name = "apple"
    private let synthesizer = AVSpeechSynthesizer()
    private let completion = SpeechCompletion()

    func prepare() async {}

    func speak(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = SpeechVoice.best(language: SpeechVoice.callLanguage)
            utterance.prefersAssistiveTechnologySettings = false
            Automation.mark("voice: speak id=\(utterance.voice?.identifier ?? "nil") assistive=false")
            completion.reset { continuation.resume() }
            synthesizer.delegate = completion
            // Buffers onto the shared playback bus (the AEC reference):
            // synthesizer.speak() plays system-side, outside echo cancellation.
            synthesizer.write(utterance) { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    self?.completion.complete() // the final empty buffer ends the utterance
                    return
                }
                AudioMeter.play(pcm)
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        AudioMeter.stopPlayback() // whatever is already scheduled on the bus
        // stopSpeaking cancels via `didCancel`, but resume here too so a hangup
        // can never leave `speak()` awaiting.
        completion.complete()
    }
}

/// Thread-safe single-shot completion shared by the synthesizer delegate and a
/// direct `stop()`, so `speak()` resumes exactly once on either path.
final class SpeechCompletion: NSObject, AVSpeechSynthesizerDelegate {
    private let lock = NSLock()
    private var finish: (() -> Void)?

    func reset(_ finish: @escaping () -> Void) {
        lock.lock()
        self.finish = finish
        lock.unlock()
    }

    func complete() {
        lock.lock()
        let finish = self.finish
        self.finish = nil
        lock.unlock()
        finish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        complete()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete()
    }
}

/// Kokoro-82M via FluidAudio's ANE pipeline. Falls back to Apple per-utterance
/// if the model cannot load or synthesize.
@MainActor
final class KokoroTtsEngine: NSObject, TtsEngine {
    let name = "kokoro"
    private var manager: KokoroAneManager?
    private let fallback = AppleTtsEngine()
    private var prepared = false
    private var prepareTask: Task<Void, Never>?
    private var finish: (() -> Void)?
    /// Set by `stop()` so a cancel during ANE synthesis does not start playback.
    private var stopRequested = false
    private(set) var lastLatencyMs: Int?

    func prepare() async {
        if prepared { return }
        if prepareTask == nil {
            prepareTask = Task { [weak self] in
                guard let self else { return }
                do {
                    Automation.mark("voice: kokoro initializing")
                    let directory = await SpeechProvisioning.directory(for: .kokoroAne)
                    let manager = KokoroAneManager(variant: .english, directory: directory)
                    try await manager.initialize()
                    self.manager = manager
                    self.prepared = true
                    Automation.mark("voice: kokoro ready")
                } catch {
                    Automation.mark("voice: kokoro init failed \(error.localizedDescription)")
                }
            }
        }
        await prepareTask?.value
    }

    func speak(_ text: String) async {
        stopRequested = false
        await prepare()
        guard prepared, let manager else {
            Automation.mark("voice: kokoro unavailable, using apple")
            await fallback.speak(text)
            return
        }
        do {
            let start = Date()
            let wav = try await manager.synthesize(text: text)
            if stopRequested { return }  // cancelled while synthesizing
            lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
            Automation.mark("voice: kokoro wav bytes=\(wav.count) in \(lastLatencyMs ?? 0)ms")
            await play(wav)
        } catch {
            Automation.mark("voice: kokoro synth failed \(error.localizedDescription); using apple")
            await fallback.speak(text)
        }
    }

    func stop() {
        stopRequested = true
        AudioMeter.stopPlayback()
        finish?()
        finish = nil
        fallback.stop()
    }

    private func play(_ wav: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The shared playback bus (the AEC reference) replaces AVAudioPlayer;
            // PlaybackBus.notify (the second ear) rides inside AudioMeter.play.
            guard let buffer = AudioMeter.buffer(wav: wav) else {
                Automation.mark("voice: kokoro play failed (decode)")
                continuation.resume()
                return
            }
            finish = { continuation.resume() }
            AudioMeter.play(buffer) { [weak self] in
                guard let self else { return }
                self.finish?()
                self.finish = nil
            }
        }
    }
}

/// Pocket TTS (Kyutai via FluidAudio) — the v4 reward-tuned small model
/// (`english_18m_refl_2026-10`; `scripts/fetch-pocket-v4.sh` provisions the
/// pack into the store root below). Trial backend (`IDFON_TTS=pocket`):
/// `IDFON_TTS_VOICE=<name>` picks a catalog voice (default alba),
/// `IDFON_TTS_CLONE=/path/voice.wav` clones a voice from a clip and speaks
/// with it. Falls back to Apple per-utterance when the model cannot load.
@MainActor
final class PocketTtsEngine: NSObject, TtsEngine {
    let name = "pocket"
    private var manager: PocketTtsManager?
    private let fallback = AppleTtsEngine()
    private var prepared = false
    private var prepareTask: Task<Void, Never>?
    private var clonedVoice: PocketTtsVoiceData?
    private var finish: (() -> Void)?
    /// Set by `stop()` so a cancel during synthesis does not start playback.
    private var stopRequested = false
    private(set) var lastLatencyMs: Int?

    func prepare() async {
        if prepared { return }
        if prepareTask == nil {
            prepareTask = Task { [weak self] in
                guard let self else { return }
                do {
                    Automation.mark("voice: pocket initializing")
                    guard #available(macOS 15.0, *) else {
                        Automation.mark("voice: pocket needs macOS 15+")
                        return
                    }
                    let voice = Self.env("IDFON_TTS_VOICE") ?? PocketTtsConstants.defaultVoice
                    let manager = PocketTtsManager(
                        defaultVoice: voice,
                        language: .english,
                        // The v4 pack lands at <root>/Models/pocket-tts-coreml/
                        // v2.1/english (the store's languageRoot for .english),
                        // so the store finds it present and downloads nothing.
                        directory: ModelStore.root.appendingPathComponent("pocket"),
                        placement: .aneState)
                    try await manager.initialize()
                    // Named cloned voices: the voices pack
                    // (scripts/fetch-pocket-voices.sh) drops
                    // <name>_audio_prompt.bin files in the voices dir.
                    if let voice = Self.env("IDFON_TTS_VOICE") {
                        let url = Self.voicesDir.appendingPathComponent("\(voice)_audio_prompt.bin")
                        if let data = try? manager.loadClonedVoice(from: url) {
                            self.clonedVoice = data
                            Automation.mark("voice: pocket voice '\(voice)' <- cloned pack")
                        }
                    }
                    if let path = Self.env("IDFON_TTS_CLONE") {
                        let wav = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                        self.clonedVoice = try await manager.cloneVoice(from: wav)
                        Automation.mark("voice: pocket cloned voice <- \(wav.lastPathComponent)")
                    }
                    self.manager = manager
                    self.prepared = true
                    Automation.mark("voice: pocket ready (voice=\(voice))")
                } catch {
                    Automation.mark("voice: pocket init failed \(error.localizedDescription)")
                }
            }
        }
        await prepareTask?.value
    }

    func speak(_ text: String) async {
        stopRequested = false
        await prepare()
        guard prepared, let manager else {
            Automation.mark("voice: pocket unavailable, using apple")
            await fallback.speak(text)
            return
        }
        do {
            let start = Date()
            let cloned = clonedVoice
            let wav = try await Self.synthesizeGuarded {
                if let cloned {
                    return try await manager.synthesize(text: text, voiceData: cloned)
                }
                return try await manager.synthesize(text: text)
            }
            if stopRequested { return }  // cancelled while synthesizing
            lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
            Automation.mark("voice: pocket wav bytes=\(wav.count) in \(lastLatencyMs ?? 0)ms")
            await play(wav)
        } catch {
            Automation.mark("voice: pocket synth failed \(error.localizedDescription); using apple")
            await fallback.speak(text)
        }
    }

    func stop() {
        stopRequested = true
        AudioMeter.stopPlayback()
        finish?()
        finish = nil
        fallback.stop()
    }

    private func play(_ wav: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let buffer = AudioMeter.buffer(wav: wav) else {
                Automation.mark("voice: pocket play failed (decode)")
                continuation.resume()
                return
            }
            finish = { continuation.resume() }
            AudioMeter.play(buffer) { [weak self] in
                guard let self else { return }
                self.finish?()
                self.finish = nil
            }
        }
    }

    private static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    /// FluidAudio 0.17.x can silently lose a session's producer task and hang
    /// synthesis forever (upstream patch: patches/FluidAudio-pocket-session-
    /// lifetime.md). Race a deadline and retry once before giving up (the
    /// caller falls back to Apple TTS).
    private static func synthesizeGuarded(
        _ body: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        for attempt in 1...2 {
            let winner: Data? = try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask { try await body() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let winner { return winner }
            Automation.mark("voice: pocket synth deadline (attempt \(attempt))")
        }
        throw NSError(domain: "pocket-tts", code: 1)
    }

    /// Cloned-voice pack directory (matches scripts/fetch-pocket-voices.sh).
    private static var voicesDir: URL {
        ModelStore.root.appendingPathComponent("pocket/voices")
    }
}

/// Adapter so the existing `MacSpeechTranscriber` fits the `AsrEngine` seam.
@available(macOS 26.0, *)
final class MacSystemAsr: AsrEngine {
    let name = "system"
    private let transcriber = MacSpeechTranscriber()

    func start(
        enableVoiceProcessing: Bool,
        onText: @escaping (String, Bool) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        try await transcriber.start(onText: onText, onError: onError)
    }

    func pause() { transcriber.pause() }
    func resume() { transcriber.resume() }
    func stop() { transcriber.stop() }
    var bargeInEngages: Bool { transcriber.bargeInEngages }
}

@MainActor
extension SpeechEngines {
    /// Caller-side context for a live-call invite: the on-device half(s) this
    /// device runs per the signed route. nil when the holder runs both, so a
    /// plain live call sends no context line.
    static func clientHalfContext(for peerID: String, route: VoiceRoute?) -> String? {
        var parts: [String] = []
        for half in route?.clientHalves ?? [] {
            switch half {
            case .recognition:
                let asr = ContactOnDeviceEngines.asr(for: peerID).flatMap(AsrBackend.init(rawValue:)) ?? asrBackend
                parts.append("Recognition: \(asr.title)")
            case .generation:
                let tts = ContactOnDeviceEngines.tts(for: peerID).flatMap(TtsBackend.init(rawValue:)) ?? ttsBackend
                parts.append("Generation: \(tts.title)")
            }
        }
        guard !parts.isEmpty else { return nil }
        return "Live call; the caller's device runs \(parts.joined(separator: "; "))."
    }
}
