import AVFAudio
import Foundation
import FluidAudio

/// Apple layout for on-device model packs: `Library/Application Support/<name>`
/// (app support files — `Documents/` is user content) with iCloud backup
/// excluded: the weights are re-downloadable and must not cost backup quota.
func modelSupportDirectory(_ name: String) -> URL {
    modelDirectory(name, in: .applicationSupportDirectory)
}

/// Cache-class model home (`Library/Caches`): packs that re-download on
/// demand live here so the file system may delete them when asked to free
/// space (`NSURLIsPurgeableKey` semantics — 2026-10-27, the tyger tier).
/// Same backup exclusion as the support-directory variant.
func modelCachesDirectory(_ name: String) -> URL {
    modelDirectory(name, in: .cachesDirectory)
}

private func modelDirectory(_ name: String, in search: FileManager.SearchPathDirectory) -> URL {
    let base = FileManager.default.urls(for: search, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var excluded = dir
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? excluded.setResourceValues(values)
    return dir
}
#if PHONON_TTS
import PhononTTS
#endif

/// Reply-speech backend for the on-device voice loop.
///
/// Kokoro (FluidAudio, ANE) is the default for English and Apple's
/// `AVSpeechSynthesizer` is the default for every other system language (and
/// the offline fallback, and the explicit alternative). Selection:
/// `IDFON_TTS=kokoro|pocket|phonon|apple` (env) or `-ttsbackend <name>`
/// (launch arg). `phonon` is the Phonon 31m option, only in builds made with
/// `IDFON_TTS_PHONON=1` (see `PhononTtsEngine`).
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
    /// Audio seconds that actually played in the current/last `speak` — the
    /// barge-history trim's `played_s` (engines that cannot measure it report
    /// 0 and callers fall back to the full text).
    var playedSeconds: TimeInterval { 0 }
}

/// Reply-speech backend choice, persisted across launches.
enum TtsBackend: String, CaseIterable {
    case kokoro
    case pocket
    case phonon
    case apple

    var title: String {
        switch self {
        case .kokoro: return "Kokoro (on-device)"
        case .pocket: return "Pocket TTS (on-device)"
        case .phonon: return "Phonon 31m (on-device)"
        case .apple: return "Apple Built-in"
        }
    }

    /// Whether this build carries the engine. `phonon` is compile-gated
    /// (`IDFON_TTS_PHONON=1` at build → `-DPHONON_TTS`); other builds hide it
    /// from pickers and fall back to Apple when a persisted pick names it.
    var isBuilt: Bool {
        #if PHONON_TTS
        return true
        #else
        return self != .phonon
        #endif
    }
}

@MainActor
enum SpeechEngines {
    /// System-language default; `IDFON_TTS`/`-ttsbackend` override for testing.
    /// Per-contact picks live in Contact Detail.
    static var backend: TtsBackend {
        if let override = overrideBackend() { return override }
        // Phonon 31m is the mouth (2026-10-25 ruling): the duplex loop needs
        // a streaming TTS, and Phonon is it. Builds without it fall back to
        // the language default.
        #if PHONON_TTS
        return .phonon
        #else
        return OnDeviceSpeechLanguage.isEnglish ? .kokoro : .apple
        #endif
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
        switch asrChoice {
        case .nemotron:
            Task {
                if #available(iOS 18.0, *) { await NemotronStreamingAsr.warmCache() }
            }
        case .parakeet:
            Task {
                if #available(iOS 18.0, *) { await ParakeetReduxAsr.warmCache() }
            }
        case .system:
            break
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
        case .phonon:
            #if PHONON_TTS
            if #available(iOS 18.0, *) { return PhononTtsEngine() }
            Automation.mark("voice: phonon needs iOS 18+; using apple")
            return AppleTtsEngine()
            #else
            Automation.mark("voice: phonon not built in (IDFON_TTS_PHONON=1 at build); using apple")
            return AppleTtsEngine()
            #endif
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
                if directory == nil, !VoiceModelGate.approved {
                    Automation.mark("voice: kokoro model download not approved")
                    return nil
                }
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
            // Explicit result type: multi-statement inference picks
            // `PocketTtsManager` from the first `return manager` and rejects `return nil`.
            let created: Task<PocketTtsManager?, Never> = Task {
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
            if clonedVoice == nil, let voice = Self.env("IDFON_TTS_VOICE") {
                // Named cloned voices: the voices pack drops
                // <name>_audio_prompt.bin files in the voices dir.
                let url = Self.voicesDir.appendingPathComponent("\(voice)_audio_prompt.bin")
                if let data = try? manager.loadClonedVoice(from: url) {
                    clonedVoice = data
                    Automation.mark("voice: pocket voice '\(voice)' <- cloned pack")
                }
            }
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

    /// Cloned-voice pack directory (side-loaded or fetched; see
    /// scripts/fetch-pocket-voices.sh for the layout).
    private static var voicesDir: URL {
        modelSupportDirectory("pocket-voices")
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

#if PHONON_TTS
/// Phonon 31m (gradium via the `ptts` Swift package) — build-time engine
/// (`IDFON_TTS_PHONON=1` at build, then `IDFON_TTS=phonon` or per-contact).
/// Models: the Core ML bundle at `Documents/phonon` (side-loaded, or fetched
/// from `IDFON_PHONON_PACK_URL` — a PhononModels export served whole:
/// bundle.json + the files it lists). Custom voices are 256KB `.safetensors`
/// embeddings dropped in `phonon/voices/NAME.safetensors`, picked with
/// `IDFON_TTS_VOICE=NAME`. Falls back to Apple per-utterance when the models
/// cannot load. iOS 18+ (the ptts package floor).
@available(iOS 18.0, *)
@MainActor
final class PhononTtsEngine: NSObject, TtsEngine {
    let name = "phonon"
    private var phonon: Phonon?
    private let fallback = AppleTtsEngine()
    private var prepared = false
    /// The model load is shared across engine instances: a call builds its own
    /// engine on top of what the prewarm warmed (KokoroTtsEngine pattern).
    private static let warmLock = NSLock()
    private static var warmTask: Task<Phonon?, Never>?
    /// Text-only playback (no call sink): a local node fed chunk by chunk.
    private var localPlayer: LocalStreamPlayer?
    private var speakTask: Task<Void, Never>?
    private var tracker: StreamTracker?
    /// The call's single playback sink (the recognizer's output bus). Mirrored
    /// onto the Apple fallback so a phonon failure renders on the same bus.
    weak var playback: AudioSink? {
        didSet { fallback.playback = playback }
    }
    /// Set by `stop()` so a cancel during synthesis does not start playback.
    private var stopRequested = false
    private(set) var lastLatencyMs: Int?

    func prepare() async {
        if prepared { return }
        let task = Self.warmLock.withLock { () -> Task<Phonon?, Never> in
            if let existing = Self.warmTask { return existing }
            // Explicit result type: multi-statement inference would pick
            // `Phonon` from the first `return phonon` and reject `return nil`.
            let created: Task<Phonon?, Never> = Task {
                Automation.mark("voice: phonon initializing")
                do {
                    let models = try await Self.modelsDirectory()
                    let phonon = try await Phonon.load(models: models, language: .english)
                    if let voice = Self.env("IDFON_TTS_VOICE") {
                        do { try await phonon.setVoice(voice) }
                        catch {
                            Automation.mark("voice: phonon voice '\(voice)' failed: \(error.localizedDescription)")
                        }
                    }
                    Automation.mark("voice: phonon ready (voice=\(phonon.voice))")
                    return phonon
                } catch {
                    Automation.mark("voice: phonon init failed \(error.localizedDescription)")
                    return nil
                }
            }
            Self.warmTask = created
            return created
        }
        if let phonon = await task.value {
            self.phonon = phonon
            prepared = true
        }
    }

    func speak(_ text: String) async {
        stopRequested = false
        await prepare()
        guard prepared, let phonon else {
            Automation.mark("voice: phonon unavailable, using apple")
            await fallback.speak(text)
            return
        }
        if let playback {
            await stream(text, phonon: phonon, playback: playback)
        } else {
            await streamLocal(text, phonon: phonon)  // text-only: local player
        }
    }

    /// Stream the utterance onto the AEC bus as it generates (80 ms chunks),
    /// so speech starts before synthesis finishes. Returns when the last chunk
    /// has played back (or the bus dropped it).
    private func stream(_ text: String, phonon: Phonon, playback: AudioSink) async {
        let start = Date()
        let tracker = StreamTracker()
        self.tracker = tracker
        let task = Task {
            do {
                try await phonon.speak(text) { chunk in
                    guard tracker.beginChunk() else { return }  // stopped
                    tracker.markFirstAudio(ms: Int(-start.timeIntervalSinceNow * 1000))
                    guard let buffer = Self.buffer(chunk) else {
                        Automation.mark("voice: phonon chunk encode failed")
                        tracker.chunkDone()
                        return
                    }
                    playback.playStream(buffer, done: tracker.chunkDone)
                }
            } catch {
                Automation.mark("voice: phonon synth failed \(error.localizedDescription)")
            }
            tracker.generatorDone()
        }
        speakTask = task
        await tracker.wait()
        speakTask = nil
        self.tracker = nil
        if let first = tracker.firstAudioMs {
            lastLatencyMs = first
            Automation.mark(
                "voice: phonon first audio \(first)ms chunks=\(tracker.chunks) total=\(Int(Date().timeIntervalSince(start) * 1000))ms")
        } else if !stopRequested {
            Automation.mark("voice: phonon generated nothing; using apple")
            await fallback.speak(text)
        }
    }

    /// Text-only path (no playback sink): stream onto a local player, so
    /// speech starts at the first generated chunk instead of after the last —
    /// Phonon's whole-clip path was its only non-streaming one.
    private func streamLocal(_ text: String, phonon: Phonon) async {
        guard let player = try? LocalStreamPlayer() else {
            Automation.mark("voice: phonon local player failed; using apple")
            await fallback.speak(text)
            return
        }
        let start = Date()
        self.localPlayer = player
        let tracker = StreamTracker()
        self.tracker = tracker
        let task = Task {
            do {
                try await phonon.speak(text) { chunk in
                    guard tracker.beginChunk() else { return }  // stopped
                    tracker.markFirstAudio(ms: Int(-start.timeIntervalSinceNow * 1000))
                    guard let buffer = Self.buffer(chunk) else {
                        Automation.mark("voice: phonon chunk encode failed")
                        tracker.chunkDone()
                        return
                    }
                    player.enqueue(buffer, done: tracker.chunkDone)
                }
            } catch {
                Automation.mark("voice: phonon synth failed \(error.localizedDescription)")
            }
            tracker.generatorDone()
        }
        speakTask = task
        await tracker.wait()
        speakTask = nil
        self.tracker = nil
        self.localPlayer = nil
        if let first = tracker.firstAudioMs {
            lastLatencyMs = first
            Automation.mark(
                "voice: phonon first audio \(first)ms chunks=\(tracker.chunks) total=\(Int(Date().timeIntervalSince(start) * 1000))ms")
        } else if !stopRequested {
            Automation.mark("voice: phonon generated nothing; using apple")
            await fallback.speak(text)
        }
    }

    func stop() {
        stopRequested = true
        tracker?.stop()
        speakTask?.cancel()  // stops generation at the next chunk
        speakTask = nil
        localPlayer?.stop()
        localPlayer = nil
        playback?.stopPlayback()
        fallback.stop()
    }

    /// The Core ML bundle in `Library/Application Support/phonon`, side-loaded
    /// or fetched from IDFON_PHONON_PACK_URL / `-phononpack <url>`
    /// (scripts/fetch-phonon-31m.sh builds the layout).
    private static func modelsDirectory() async throws -> URL {
        let dir = modelSupportDirectory("phonon")
        // The launch arg mirrors the env var: devicectl launch cannot set
        // environment variables.
        if let base = env("IDFON_PHONON_PACK_URL") ?? launchString("-phononpack"), let url = URL(string: base) {
            return try await PhononModels.download(from: url, to: dir)
        }
        guard PhononModels.isInstalled(at: dir) else {
            throw PhononError(
                description: "no phonon models at \(dir.path); side-load the bundle or set IDFON_PHONON_PACK_URL")
        }
        return dir
    }

    /// f32 mono @24kHz chunk -> buffer for the playback bus.
    /// nonisolated: called from the generator's audio callback thread.
    private nonisolated static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Phonon.sampleRate, channels: 1,
                interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress, let dst = buffer.floatChannelData?[0] else { return }
            dst.update(from: base, count: samples.count)
        }
        return buffer
    }

    private static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    private static func launchString(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: flag), args.count > index + 1 {
            return args[index + 1]
        }
        return nil
    }
}

/// Tracks a streamed utterance: `wait()` resumes once generation is done and
/// every scheduled chunk has played back (a bus stop fires the completions
/// too, so `wait` cannot hang on a barge).
private final class StreamTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0
    private var generated = false
    private var stopped = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var firstAudioMs: Int?
    private(set) var chunks = 0

    /// Enqueue accounting for one chunk; false once stopped (drop the chunk).
    func beginChunk() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return false }
        outstanding += 1
        chunks += 1
        return true
    }

    func chunkDone() {
        lock.lock()
        outstanding -= 1
        let done = generated && outstanding <= 0
        lock.unlock()
        if done { finish() }
    }

    func generatorDone() {
        lock.lock()
        generated = true
        let done = outstanding <= 0
        lock.unlock()
        if done { finish() }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func markFirstAudio(ms: Int) {
        lock.lock()
        if firstAudioMs == nil { firstAudioMs = ms }
        lock.unlock()
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if generated && outstanding <= 0 {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }

    private func finish() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

/// Text-only playback for `PhononTtsEngine`: chunks as they generate on a
/// local `AVAudioPlayerNode`. Per-chunk completions feed `StreamTracker`, so
/// `speak` still returns when the audio has finished playing (the package's
/// `PhononPlayer` enqueues but never reports playback). Only used when no call
/// sink owns the session.
@available(iOS 18.0, *)
private final class LocalStreamPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Phonon.sampleRate, channels: 1)!

    init() throws {
        // Text-only only: a live call owns the session via AudioIO.
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.play()
    }

    /// Queue one chunk; `done` fires when it has played back (or was stopped).
    func enqueue(_ buffer: AVAudioPCMBuffer, done: @escaping () -> Void) {
        node.scheduleBuffer(buffer, completionHandler: done)
    }

    func stop() {
        node.stop()  // flushes scheduled chunks; their completions drain the tracker
        engine.stop()
    }
}
#endif

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
    /// A turn committed (or the current utterance was cleared): streaming
    /// recognizers whose transcript accumulates across turns reset here so
    /// their partials stay per-utterance. A protocol REQUIREMENT — an
    /// extension-only method dispatches statically through `any AsrEngine`
    /// and silently skips conforming overrides (the accumulation bug).
    func utteranceCommitted()
}

extension AsrEngine {
    var lastLatencyMs: Int? { nil }
    func prepare() async {}
    /// A turn committed (or the current utterance was cleared): streaming
    /// recognizers whose transcript accumulates across turns reset here so
    /// their partials stay per-utterance. No-op for recognizers that segment
    /// internally.
    func utteranceCommitted() {}
}

enum AsrBackend: String, CaseIterable {
    case system
    case nemotron
    case parakeet

    var title: String {
        switch self {
        case .system: return "Apple Built-in"
        case .nemotron: return "Nemotron Streaming (on-device)"
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
        return OnDeviceSpeechLanguage.isEnglish ? .nemotron : .system
    }

    /// The configured recognizer, or nil to use the SFSpeech fallback (system
    /// backend on iOS < 26).
    static func makeAsr() -> (any AsrEngine)? { makeAsr(asrBackend) }

    /// Build a recognizer for `backend`, independent of the persisted global
    /// choice (per-contact on-device selection).
    static func makeAsr(_ backend: AsrBackend) -> (any AsrEngine)? {
        switch backend {
        case .nemotron:
            guard #available(iOS 18.0, *) else { return nil }
            Automation.mark("voice: asr backend=nemotron")
            return NemotronStreamingAsr()
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
