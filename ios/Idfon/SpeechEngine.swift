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

@MainActor
enum SpeechEngines {
    static let tts: TtsEngine = {
        let requested = (ProcessInfo.processInfo.environment["IDFON_TTS"] ?? launchArg()).lowercased()
        switch requested {
        case "apple":
            Automation.mark("voice: tts backend=apple")
            return AppleTtsEngine()
        default:
            Automation.mark("voice: tts backend=kokoro")
            return KokoroTtsEngine()
        }
    }()

    /// Warm the selected engine in the background so the first call's reply is
    /// not blocked by a cold model download/compile.
    static func prewarm() {
        Task { await tts.prepare() }
    }

    private static func launchArg() -> String {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-ttsbackend"), args.count > index + 1 {
            return args[index + 1]
        }
        return "kokoro"
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
    private let manager = KokoroAneManager(variant: .english)
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
                    try await self.manager.initialize()
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
        guard prepared else {
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
