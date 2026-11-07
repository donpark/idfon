import AVFAudio
import CryptoKit
import Foundation

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
/// Phonon 31m (streaming) is the default when the build carries it
/// (`PHONON_TTS`, the default since the 2026-10-25 ruling: the duplex loop
/// needs a streaming mouth). Builds without Phonon fall back to Apple's
/// `AVSpeechSynthesizer` (the offline fallback and the explicit alternative).
/// Selection: `IDFON_TTS=phonon|apple` (env) or `-ttsbackend
/// <name>` (launch arg); `IDFON_TTS_PHONON=0` builds Phonon out.
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
    case phonon
    case apple

    var title: String {
        switch self {
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
        return .apple
        #endif
    }

    /// The active engine; read by `VoiceAgentSession` at call time.
    static var tts: TtsEngine = makeTts(backend)

    /// Warm the speech engines in the background so a call is not blocked by a
    /// cold model download/compile. `asr`/`tts` are a contact's selected
    /// backend ids (ContactOnDeviceEngines); nil warms the app defaults. The
    /// model work is shared across engine instances, so this also covers the fresh engines
    /// a call builds for itself.
    static func prewarm(asr: String? = nil, tts: String? = nil) {
        let ttsChoice = tts.flatMap(TtsBackend.init(rawValue:)) ?? backend
        Task { await makeTts(ttsChoice).prepare() }
        Task { await BackchannelCache.shared.prepare(backend: ttsChoice, language: SpeechVoice.callLanguage) }
        let asrChoice = asr.flatMap(AsrBackend.init(rawValue:)) ?? asrBackend
        switch asrChoice {
        case .nemotron:
            Task {
                if #available(iOS 18.0, *) { await NemotronStreamingAsr.warmCache() }
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
    private var tracker: StreamTracker?
    private(set) var lastLatencyMs: Int?

    func prepare() async {}

    func speak(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoice.best(language: SpeechVoice.callLanguage)
        utterance.prefersAssistiveTechnologySettings = false
        Automation.mark("voice: speak id=\(utterance.voice?.identifier ?? "nil") assistive=false")
        // Stream through the call's single playback sink when one is wired, so
        // Apple TTS plays on the echo-cancellation reference instead of the
        // synthesizer's private output (docs/voice-side-channel.md).
        if let sink = playback {
            await stream(utterance, to: sink)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completion.reset { continuation.resume() }
            synthesizer.delegate = completion
            synthesizer.speak(utterance)
        }
    }

    /// `write` buffers go onto the bus as they arrive: the Apple fallback must
    /// meet Phonon's contract (first audio before the utterance ends, and a
    /// chunk-cancel barge). Whole-clip rendering made a barge unable to stop
    /// the reply (2026-11-07 device log).
    private func stream(_ utterance: AVSpeechUtterance, to sink: AudioSink) async {
        let start = Date()
        let tracker = StreamTracker()
        self.tracker = tracker
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                tracker.generatorDone() // the final empty buffer ends the utterance
                return
            }
            guard tracker.beginChunk() else { return }
            tracker.markFirstAudio(ms: Int(-start.timeIntervalSinceNow * 1000))
            sink.playStream(pcm, done: tracker.chunkDone)
        }
        await tracker.wait()
        if let first = tracker.firstAudioMs {
            lastLatencyMs = first
            Automation.mark(
                "voice: apple first audio \(first)ms chunks=\(tracker.chunks) total=\(Int(Date().timeIntervalSince(start) * 1000))ms")
        }
        self.tracker = nil
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        // stopSpeaking cancels via `didCancel`, but resume here too so a hangup
        // can never leave `speak()` awaiting.
        completion.complete()
        tracker?.stop()
        playback?.stopPlayback()
        tracker = nil
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

#if PHONON_TTS
/// Downloads a Phonon pack from a content-addressed base. The download index is
/// `pack.json` at the base (mutable, `no-store`); every file is fetched from
/// `sha256/<sha256>` (immutable) and installed at its manifest `path`, so the
/// Core ML package layout and the voice filenames survive the move to the CDN.
///
/// `bundle.json` is **not** ours: it is Phonon's model metadata (dims, ctx,
/// languages) and ships as a regular listed file. Writing the index over it is
/// what made every pack since 2026-11-01 unloadable ("bundle.json has no dims").
/// Phonon 31m (gradium via the `ptts` Swift package) — build-time engine
/// (`IDFON_TTS_PHONON=1` at build, then `IDFON_TTS=phonon` or per-contact).
/// Models: the Core ML bundle at `Documents/phonon` (side-loaded, or fetched
/// from `IDFON_PHONON_PACK_URL` — a PhononModels export served whole:
/// pack.json (index) + bundle.json (model metadata) + files fetched from
/// `sha256/<hash>` — or from `defaultPackURL`, the baked-in
/// production pack). Custom voices are 256KB `.safetensors`
/// embeddings dropped in `phonon/voices/NAME.safetensors`, picked with
/// `IDFON_TTS_VOICE=NAME` (default: Clara, an idfon blend voice). Falls back to Apple per-utterance when the models
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
                    // The load is what compiles the packages; link the compiled
                    // copies of the duplicated flow weights (PhononPack).
                    PhononPack.relinkCompiled(at: models)
                    let voice = Self.env("IDFON_TTS_VOICE") ?? "Clara"
                    do { try await phonon.setVoice(voice) }
                    catch {
                        Automation.mark("voice: phonon voice '\(voice)' failed: \(error)")
                    }
                    Automation.mark("voice: phonon ready (voice=\(phonon.voice))")
                    return phonon
                } catch {
                    Automation.mark("voice: phonon init failed \(error)")
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
                Automation.mark("voice: phonon synth failed \(error)")
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
                Automation.mark("voice: phonon synth failed \(error)")
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
    /// Dev overrides: IDFON_PHONON_PACK_URL / -phononpack. nil disables fetching.
    static let defaultPackURL: String? = "https://files.idfon.net/models/phonon-31m/"

    private static func modelsDirectory() async throws -> URL {
        let dir = modelSupportDirectory("phonon")
        // The launch arg mirrors the env var: devicectl launch cannot set
        // environment variables.
        if let base = env("IDFON_PHONON_PACK_URL") ?? launchString("-phononpack") ?? defaultPackURL,
           let url = URL(string: base) {
            return try await PhononPack.download(from: url, to: dir)
        }
        // Off the main actor: this hashes the whole pack.
        let ok = await Task.detached { PhononPack.verified(at: dir) }.value
        guard ok else {
            throw PhononError(
                description: "phonon models at \(dir.path) are missing or damaged; side-load the bundle or set IDFON_PHONON_PACK_URL")
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
        finish() // a stop must not leave `wait()` hanging (Apple's write has no end marker after cancel)
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

    var title: String {
        switch self {
        case .system: return "Apple Built-in"
        case .nemotron: return "Nemotron Streaming (on-device)"
        }
    }
}

/// The on-device neural engines are English-only (Nemotron ASR, Phonon TTS).
/// Other system languages get the Apple built-ins, which follow the system
/// locale.
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
