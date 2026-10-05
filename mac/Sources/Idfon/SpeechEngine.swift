import AVFAudio
import Foundation
import FluidAudio

/// Reply-speech backend for the on-device voice loop (macOS port of
/// `ios/Idfon/SpeechEngine.swift`).
///
/// Kokoro (FluidAudio, ANE) is the default; Apple's `AVSpeechSynthesizer` is
/// both the offline fallback and the explicit alternative. Selection:
/// `IDFON_TTS=kokoro|apple` (env) or `-ttsbackend <name>` (launch arg).
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
    case apple

    var title: String {
        switch self {
        case .kokoro: return "Kokoro (on-device neural)"
        case .apple: return "Apple (system voice)"
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
}

extension AsrEngine {
    var lastLatencyMs: Int? { nil }
    func prepare() async {}
    /// Whether recent input loudness is enough to count as barge-in on a
    /// no-AEC platform (macOS gated mode). Defaults to true (AEC platforms).
    var bargeInEngages: Bool { true }
}

enum AsrBackend: String, CaseIterable {
    case system
    case parakeet

    var title: String {
        switch self {
        case .system: return "Apple (SpeechAnalyzer)"
        case .parakeet: return "Parakeet Redux (on-device)"
        }
    }
}

@MainActor
enum SpeechEngines {
    private static let ttsKey = "idfon.tts-backend"
    private static let asrKey = "idfon.asr-backend"

    /// The active engine; read by `VoiceAgentSession` at call time.
    static var tts: TtsEngine = makeTts(ttsBackend)

    /// Persisted reply-voice choice; `IDFON_TTS`/`-ttsbackend` override.
    static var ttsBackend: TtsBackend {
        if let override = overrideTts() { return override }
        if let raw = UserDefaults.standard.string(forKey: ttsKey),
           let value = TtsBackend(rawValue: raw) {
            return value
        }
        return .kokoro
    }

    static func setBackend(_ backend: TtsBackend) {
        UserDefaults.standard.set(backend.rawValue, forKey: ttsKey)
        tts = makeTts(backend)
        prewarm()
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

    /// Persisted recognizer choice; `IDFON_ASR`/`-asrbackend` override.
    static var asrBackend: AsrBackend {
        let override = ProcessInfo.processInfo.environment["IDFON_ASR"] ?? asrLaunchArg()
        if let override, !override.isEmpty {
            return AsrBackend(rawValue: override.lowercased()) ?? .system
        }
        if let raw = UserDefaults.standard.string(forKey: asrKey),
           let value = AsrBackend(rawValue: raw) {
            return value
        }
        return .system
    }

    static func setAsrBackend(_ backend: AsrBackend) {
        UserDefaults.standard.set(backend.rawValue, forKey: asrKey)
        prewarm()
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
        }
    }

    private static func overrideTts() -> TtsBackend? {
        let value = ProcessInfo.processInfo.environment["IDFON_TTS"] ?? ttsLaunchArg()
        guard let value, !value.isEmpty else { return nil }
        return value.lowercased() == "apple" ? .apple : .kokoro
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
            utterance.voice = SpeechVoice.best(language: "en-US")
            utterance.prefersAssistiveTechnologySettings = false
            Automation.mark("voice: speak id=\(utterance.voice?.identifier ?? "nil") assistive=false")
            completion.reset { continuation.resume() }
            synthesizer.delegate = completion
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
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
    private var player: AVAudioPlayer?
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
        player?.stop()
        finish?()
        finish = nil
        player = nil
        fallback.stop()
    }

    private func play(_ wav: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            do {
                let player = try AVAudioPlayer(data: wav)
                player.delegate = self
                finish = { continuation.resume() }
                self.player = player
                player.play()
            } catch {
                Automation.mark("voice: kokoro play failed \(error.localizedDescription)")
                continuation.resume()
            }
        }
    }
}

extension KokoroTtsEngine: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish?()
        finish = nil
        self.player = nil
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
