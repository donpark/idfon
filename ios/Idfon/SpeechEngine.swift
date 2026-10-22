import AVFAudio
import Foundation
import FluidAudio

/// Reply-speech backend for the on-device voice loop.
///
/// Kokoro (FluidAudio, ANE) is the default for English and Apple's
/// `AVSpeechSynthesizer` is the default for every other system language (and
/// the offline fallback, and the explicit alternative). Selection:
/// `IDFON_TTS=kokoro|apple` (env) or `-ttsbackend <name>` (launch arg).
@MainActor
protocol TtsEngine: AnyObject {
    var name: String { get }
    /// Wall time of the last `speak`, in ms (nil when not measured).
    var lastLatencyMs: Int? { get }
    /// The call's single playback sink (the recognizer's output bus), so TTS
    /// audio is the echo-cancellation reference. See `AudioIO`/
    /// `docs/voice-side-channel.md`.
    var playback: AudioSink? { get set }
    /// Download/load models if needed (no-op for Apple).
    func prepare() async
    /// Speak `text`, returning when playback finishes.
    func speak(_ text: String) async
    func stop()
}

extension TtsEngine {
    var lastLatencyMs: Int? { nil }
    var playback: AudioSink? { get { nil } set {} }
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

@MainActor
enum SpeechEngines {
    /// System-language default; `IDFON_TTS`/`-ttsbackend` override for testing.
    /// Per-contact picks live in Contact Detail.
    static var backend: TtsBackend {
        if let override = overrideBackend() { return override }
        return OnDeviceSpeechLanguage.isEnglish ? .kokoro : .apple
    }

    /// The active engine; read by `VoiceAgentSession` at call time.
    static var tts: TtsEngine = makeTts(backend)

    /// Warm the speech engines in the background so a call is not blocked by a
    /// cold model download/compile. `asr`/`tts` are a contact's selected
    /// backend ids (ContactOnDeviceEngines); nil warms the app defaults. The
    /// model work is shared across engine instances (ParakeetReduxAsr.warmCache,
    /// KokoroTtsEngine's shared manager), so this also covers the fresh engines
    /// a call builds for itself.
    static func prewarm(asr: String? = nil, tts: String? = nil) {
        let ttsChoice = tts.flatMap(TtsBackend.init(rawValue:)) ?? backend
        Task { await makeTts(ttsChoice).prepare() }
        let asrChoice = asr.flatMap(AsrBackend.init(rawValue:)) ?? asrBackend
        if asrChoice == .parakeet {
            Task {
                if #available(iOS 18.0, *) { await ParakeetReduxAsr.warmCache() }
            }
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

    private static func overrideBackend() -> TtsBackend? {
        let value = ProcessInfo.processInfo.environment["IDFON_TTS"] ?? launchArg()
        guard let value, !value.isEmpty else { return nil }
        return TtsBackend(rawValue: value.lowercased())
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
    private let completion = SpeechCompletion()

    func prepare() async {}

    func speak(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoice.best(language: SpeechVoice.callLanguage)
        utterance.prefersAssistiveTechnologySettings = false
        Automation.mark("voice: speak id=\(utterance.voice?.identifier ?? "nil") assistive=false")
        // Render through the call's single playback sink when one is wired, so
        // Apple TTS plays on the echo-cancellation reference instead of the
        // synthesizer's private output (docs/voice-side-channel.md).
        if let sink = playback {
            for chunk in await Self.render(utterance, with: synthesizer) {
                await sink.play(chunk)
            }
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
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

    /// Render an utterance to PCM via `write(_:toBufferCallback:)` (iOS 13+).
    /// The callback delivers a zero-length buffer at end of stream.
    private static func render(
        _ utterance: AVSpeechUtterance, with synthesizer: AVSpeechSynthesizer
    ) async -> [AVAudioPCMBuffer] {
        let collector = SpeechBufferCollector()
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                collector.finish()
                return
            }
            collector.add(pcm)
        }
        return await collector.wait(timeout: 15)
    }
}

/// Collects the PCM chunks `AVSpeechSynthesizer.write` streams, completing once
/// (on the end-of-stream marker or a timeout) so `speak()` can never hang.
private final class SpeechBufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?
    private var finished = false

    func add(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if !finished { chunks.append(buffer) }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let result = chunks
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func wait(timeout: TimeInterval) async -> [AVAudioPCMBuffer] {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.finish()
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                let result = chunks
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
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
    /// The model load is shared across engine instances: a call builds its own
    /// engine on top of what the prewarm warmed (ParakeetReduxAsr.warmCache
    /// pattern), so per-instance prepare would pay the load again.
    private static let warmLock = NSLock()
    private static var warmTask: Task<KokoroAneManager?, Never>?
    private var player: AVAudioPlayer?
    private var finish: (() -> Void)?
    /// The call's single playback sink (`VoiceAgentSession` wires `AudioIO`).
    /// Mirrored onto the Apple fallback so a Kokoro failure still renders on
    /// the same bus (and its AEC reference).
    weak var playback: AudioSink? {
        didSet { fallback.playback = playback }
    }
    /// Set by `stop()` so a cancel during ANE synthesis does not start playback.
    private var stopRequested = false
    private(set) var lastLatencyMs: Int?

    func prepare() async {
        if prepared { return }
        let task = Self.warmLock.withLock { () -> Task<KokoroAneManager?, Never> in
            if let existing = Self.warmTask { return existing }
            let created: Task<KokoroAneManager?, Never> = Task {
                Automation.mark("voice: kokoro initializing")
                // Apple-managed asset pack when configured; else FluidAudio's
                // own HuggingFace download (directory == nil).
                let directory = await SpeechProvisioning.directory(for: .kokoroAne)
                let manager = KokoroAneManager(variant: .english, directory: directory)
                do {
                    try await manager.initialize()
                    Automation.mark("voice: kokoro ready")
                    return manager
                } catch {
                    Automation.mark("voice: kokoro init failed \(error.localizedDescription)")
                    return nil
                }
            }
            Self.warmTask = created
            return created
        }
        if let manager = await task.value {
            self.manager = manager
            prepared = true
        }
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
        playback?.stopPlayback()
        fallback.stop()
    }

    private func play(_ wav: Data) async {
        // Prefer the recognizer's VPIO engine: its output bus is the AEC
        // reference, so the mic can stay live (barge-in) without the agent
        // transcribing its own TTS. Fall back to a local player when no
        // recognizer is wired (text-only mode).
        if let playback {
            await playback.play(wav: wav)
            return
        }
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

/// Pocket TTS (Kyutai via FluidAudio) — the v4 reward-tuned small model
/// trial (`IDFON_TTS=pocket`): `IDFON_TTS_VOICE=<name>` picks a catalog
/// voice (default alba), `IDFON_TTS_CLONE=/path/voice.wav` clones a voice
/// from a clip and speaks with it. Falls back to Apple per-utterance when
/// the model cannot load.
final class PocketTtsEngine: NSObject, TtsEngine {
    let name = "pocket"
    private var manager: PocketTtsManager?
    private let fallback = AppleTtsEngine()
    private var prepared = false
    /// The model load is shared across engine instances (KokoroTtsEngine's
    /// shared-manager pattern): a call builds its own engine on top of what
    /// the prewarm warmed.
    private static let warmLock = NSLock()
    private static var warmTask: Task<PocketTtsManager?, Never>?
    private var clonedVoice: PocketTtsVoiceData?
    private var player: AVAudioPlayer?
    private var finish: (() -> Void)?
    /// The call's single playback sink (the recognizer's output bus), so TTS
    /// audio is the echo-cancellation reference. Mirrored onto the fallback.
    weak var playback: AudioSink? {
        didSet { fallback.playback = playback }
    }
    /// Set by `stop()` so a cancel during synthesis does not start playback.
    private var stopRequested = false
    private(set) var lastLatencyMs: Int?

    func prepare() async {
        if prepared { return }
        let task = Self.warmLock.withLock { () -> Task<PocketTtsManager?, Never> in
            if let existing = Self.warmTask { return existing }
            let created = Task {
                Automation.mark("voice: pocket initializing")
                if #available(iOS 18.0, *) {
                    let voice = Self.env("IDFON_TTS_VOICE") ?? PocketTtsConstants.defaultVoice
                    let manager = PocketTtsManager(defaultVoice: voice, language: .english, placement: .aneState)
                    do {
                        try await manager.initialize()
                        Automation.mark("voice: pocket ready (voice=\(voice))")
                        return manager
                    } catch {
                        Automation.mark("voice: pocket init failed \(error.localizedDescription)")
                        return nil
                    }
                }
                Automation.mark("voice: pocket needs iOS 18+")
                return nil
            }
            Self.warmTask = created
            return created
        }
        if let manager = await task.value {
            self.manager = manager
            prepared = true
            if clonedVoice == nil, let path = Self.env("IDFON_TTS_CLONE") {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                clonedVoice = try? await manager.cloneVoice(from: url)
                if clonedVoice != nil {
                    Automation.mark("voice: pocket cloned voice <- \(url.lastPathComponent)")
                }
            }
        }
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
            let wav: Data
            if let clonedVoice {
                wav = try await manager.synthesize(text: text, voiceData: clonedVoice)
            } else {
                wav = try await manager.synthesize(text: text)
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
        player?.stop()
        finish?()
        finish = nil
        player = nil
        playback?.stopPlayback()
        fallback.stop()
    }

    private func play(_ wav: Data) async {
        // Prefer the recognizer's VPIO engine: its output bus is the AEC
        // reference (the KokoroTtsEngine pattern).
        if let playback {
            await playback.play(wav: wav)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            do {
                let player = try AVAudioPlayer(data: wav)
                player.delegate = self
                finish = { continuation.resume() }
                self.player = player
                player.play()
            } catch {
                Automation.mark("voice: pocket play failed \(error.localizedDescription)")
                continuation.resume()
            }
        }
    }

    private static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }
}

extension PocketTtsEngine: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish?()
        finish = nil
        self.player = nil
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
/// `AppleSpeechTranscriber`'s surface so the loop is engine-agnostic.
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

extension SpeechEngines {
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
    /// backend on iOS < 26).
    static func makeAsr() -> (any AsrEngine)? { makeAsr(asrBackend) }

    /// Build a recognizer for `backend`, independent of the persisted global
    /// choice (per-contact on-device selection).
    static func makeAsr(_ backend: AsrBackend) -> (any AsrEngine)? {
        switch backend {
        case .parakeet:
            guard #available(iOS 18.0, *) else { return nil }
            Automation.mark("voice: asr backend=parakeet")
            return ParakeetReduxAsr()
        case .system:
            if #available(iOS 26.0, *) {
                Automation.mark("voice: asr backend=system")
                return AppleSpeechTranscriber()
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
extension AppleSpeechTranscriber: AsrEngine {
    var name: String { "system" }
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
                let tts = ContactOnDeviceEngines.tts(for: peerID).flatMap(TtsBackend.init(rawValue:)) ?? backend
                parts.append("Generation: \(tts.title)")
            }
        }
        guard !parts.isEmpty else { return nil }
        return "Live call; the caller's device runs \(parts.joined(separator: "; "))."
    }
}
