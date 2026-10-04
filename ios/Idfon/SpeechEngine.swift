import AVFAudio
import Foundation
import FluidAudio

/// Reply-speech backend for the on-device voice loop.
///
/// Kokoro (FluidAudio, ANE) is the default; Apple's `AVSpeechSynthesizer` is
/// both the offline fallback and the explicit alternative. Selection:
/// `IDFON_TTS=kokoro|apple` (env) or `-ttsbackend <name>` (launch arg).
@MainActor
protocol TtsEngine: AnyObject {
    var name: String { get }
    /// Download/load models if needed (no-op for Apple).
    func prepare() async
    /// Speak `text`, returning when playback finishes.
    func speak(_ text: String) async
    func stop()
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

@MainActor
enum SpeechEngines {
    private static let defaultsKey = "idfon.tts-backend"

    /// Persisted choice; `IDFON_TTS`/`-ttsbackend` override for testing.
    static var backend: TtsBackend {
        if let override = overrideBackend() { return override }
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let value = TtsBackend(rawValue: raw) {
            return value
        }
        return .kokoro
    }

    /// The active engine; read by `VoiceAgentSession` at call time.
    static var tts: TtsEngine = make(backend)

    static func setBackend(_ backend: TtsBackend) {
        UserDefaults.standard.set(backend.rawValue, forKey: defaultsKey)
        tts = make(backend)
        prewarm()
    }

    /// Warm the selected engine in the background so the first call's reply is
    /// not blocked by a cold model download/compile.
    static func prewarm() {
        Task { await tts.prepare() }
    }

    private static func make(_ backend: TtsBackend) -> TtsEngine {
        Automation.mark("voice: tts backend=\(backend.rawValue)")
        switch backend {
        case .apple: return AppleTtsEngine()
        case .kokoro: return KokoroTtsEngine()
        }
    }

    private static func overrideBackend() -> TtsBackend? {
        let value = ProcessInfo.processInfo.environment["IDFON_TTS"] ?? launchArg()
        guard let value, !value.isEmpty else { return nil }
        return value.lowercased() == "apple" ? .apple : .kokoro
    }

    private static func launchArg() -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-ttsbackend"), args.count > index + 1 {
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
    private var delegate: SpeechDelegate?

    func prepare() async {}

    func speak(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = SpeechVoice.best(language: "en-US")
            utterance.prefersAssistiveTechnologySettings = false
            Automation.mark("voice: speak id=\(utterance.voice?.identifier ?? "nil") assistive=false")
            let delegate = SpeechDelegate { continuation.resume() }
            self.delegate = delegate
            synthesizer.delegate = delegate
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
        let finish: () -> Void
        init(finish: @escaping () -> Void) { self.finish = finish }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            finish()
        }
    }
}

/// Kokoro-82M via FluidAudio's ANE pipeline. Falls back to Apple per-utterance
/// if the model cannot load or synthesize.
///
/// Risk: FluidAudio documents an uncatchable iOS 27 Core ML crash
/// (libBNNS/MPSGraph, issues #843/#889); short calls survive, long sessions
/// (~1 h cumulative synthesis) can die. There is no non-ANE Kokoro backend to
/// fall back to, so the escape hatch is Chatterbox Nano or Kokoro ONNX.
@MainActor
final class KokoroTtsEngine: NSObject, TtsEngine {
    let name = "kokoro"
    private var manager: KokoroAneManager?
    private let fallback = AppleTtsEngine()
    private var prepared = false
    private var prepareTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var finish: (() -> Void)?

    func prepare() async {
        if prepared { return }
        if prepareTask == nil {
            prepareTask = Task { [weak self] in
                guard let self else { return }
                do {
                    Automation.mark("voice: kokoro initializing")
                    // Apple-managed asset pack when configured; else FluidAudio's
                    // own HuggingFace download (directory == nil).
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
        await prepare()
        guard prepared, let manager else {
            Automation.mark("voice: kokoro unavailable, using apple")
            await fallback.speak(text)
            return
        }
        do {
            let start = Date()
            let wav = try await manager.synthesize(text: text)
            Automation.mark("voice: kokoro wav bytes=\(wav.count) in \(Int(Date().timeIntervalSince(start) * 1000))ms")
            await play(wav)
        } catch {
            Automation.mark("voice: kokoro synth failed \(error.localizedDescription); using apple")
            await fallback.speak(text)
        }
    }

    func stop() {
        player?.stop()
        finish?()
        finish = nil
        player = nil
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

// MARK: - Speech recognition

/// On-device recognizer behind the voice loop. Mirrors
/// `SystemSpeechTranscriber`'s surface so the loop is engine-agnostic.
protocol AsrEngine: AnyObject {
    var name: String { get }
    func start(
        enableVoiceProcessing: Bool,
        onText: @escaping (String, Bool) -> Void,
        onError: @escaping (String) -> Void
    ) async throws
    func pause()
    func resume()
    func stop()
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

extension SpeechEngines {
    private static let asrDefaultsKey = "idfon.asr-backend"

    /// Persisted recognizer choice; `IDFON_ASR`/`-asrbackend` override.
    static var asrBackend: AsrBackend {
        let override = ProcessInfo.processInfo.environment["IDFON_ASR"] ?? asrLaunchArg()
        if let override, !override.isEmpty {
            return override.lowercased() == "parakeet" ? .parakeet : .system
        }
        if let raw = UserDefaults.standard.string(forKey: asrDefaultsKey),
           let value = AsrBackend(rawValue: raw) {
            return value
        }
        return .system
    }

    static func setAsrBackend(_ backend: AsrBackend) {
        UserDefaults.standard.set(backend.rawValue, forKey: asrDefaultsKey)
    }

    /// The configured recognizer, or nil to use the SFSpeech fallback (system
    /// backend on iOS < 26).
    static func makeAsr() -> (any AsrEngine)? {
        switch asrBackend {
        case .parakeet:
            guard #available(iOS 18.0, *) else { return nil }
            Automation.mark("voice: asr backend=parakeet")
            return ParakeetReduxAsr()
        case .system:
            if #available(iOS 26.0, *) {
                Automation.mark("voice: asr backend=system")
                return SystemSpeechTranscriber()
            }
            return nil
        }
    }

    private static func asrLaunchArg() -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-asrbackend"), args.count > index + 1 {
            return args[index + 1]
        }
        return nil
    }
}

@available(iOS 26.0, *)
extension SystemSpeechTranscriber: AsrEngine {
    var name: String { "system" }
}
