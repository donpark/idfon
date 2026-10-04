import AVFAudio
import Foundation

/// Whistle (Cactus Compute) speech recognition via the Needle C engine.
///
/// Whistle is a whole-clip recognizer — 16 kHz mono PCM, up to 30 s in one
/// pass, CPU-only — not a streaming one. This adapter taps the mic, runs a
/// small energy endpointer (speech ≥0.3 s, then 0.8 s of quiet), and calls
/// `needle_transcribe` on the utterance, emitting the text as a final. The
/// loop's `VoicePromptSegmenter` commits it like any other final.
///
/// Model: `whistle.cact` (16.9 MB), provisioned via `SpeechProvisioning`
/// (`IDFON_WHISTLE_PACK_URL` / `-whistlepackurl`). Apache-2.0.
@available(iOS 18.0, *)
final class WhistleAsr: AsrEngine {
    let name = "whistle"

    private let engine = AVAudioEngine()
    /// The Needle engine is process-global and not thread-safe; all model
    /// calls are serialized here.
    private let work = DispatchQueue(label: "idfon.whistle")
    private let lock = NSLock()
    private let sampleRate = 16_000.0
    private let maxClip = 30.0 * 16_000.0

    // Energy endpointer thresholds (RMS over a tap buffer).
    private static let speechRMS: Float = 0.006
    private static let minSpeech = 0.3
    private static let silence = 0.8

    private var onText: ((String, Bool) -> Void)?
    private var converter: AVAudioConverter?
    private var captureFormat: AVAudioFormat?
    private var started = false
    /// Newline-separated phrases Whistle biases its beam search toward, so
    /// app-specific proper nouns survive ("idfon", contact names).
    private var keywords = "idfon"

    // Endpointer state, guarded by `lock`.
    private var gated = true
    private var samples: [Float] = []
    private var speaking = false
    private var quietCount = 0
    private var speechCount = 0

    private enum WhistleError: LocalizedError {
        case notProvisioned
        case load(String)
        case format

        var errorDescription: String? {
            switch self {
            case .notProvisioned: return "whistle.cact not provisioned"
            case .load(let message): return "needle_load failed: \(message)"
            case .format: return "could not build the 16 kHz capture format"
            }
        }
    }

    func start(
        enableVoiceProcessing: Bool,
        onText: @escaping (String, Bool) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        self.onText = onText
        let bytes = try await Self.loadModel()
        Automation.mark("voice: whistle ready bytes=\(bytes)")
        keywords = await Self.keywordList()
        Automation.mark("voice: whistle keywords=\(keywords.replacingOccurrences(of: "\n", with: ","))")
        _ = onError  // batch engine: failures return an empty transcript

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
            throw WhistleError.format
        }
        self.captureFormat = captureFormat
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        engine.prepare()
        try engine.start()
        started = true
        setGated(false)
    }

    func pause() {
        setGated(true)
        lock.lock(); resetLocked(); lock.unlock()
    }

    func resume() {
        lock.lock(); resetLocked(); lock.unlock()
        setGated(false)
        if started, !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    func stop() {
        guard started else { return }
        started = false
        setGated(true)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        captureFormat = nil
        lock.lock(); resetLocked(); lock.unlock()
    }

    // MARK: - capture

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard !isGated, let converter, let captureFormat else { return }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        var provided = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        accumulate(Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength))))
    }

    private func accumulate(_ chunk: [Float]) {
        lock.lock()
        guard !gated else { lock.unlock(); return }
        samples.append(contentsOf: chunk)
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(1, chunk.count)))
        if rms > Self.speechRMS {
            speaking = true
            quietCount = 0
            speechCount += chunk.count
        } else if speaking {
            quietCount += chunk.count
        }
        let ended = speaking
            && speechCount >= Int(Self.minSpeech * sampleRate)
            && quietCount >= Int(Self.silence * sampleRate)
        let tooLong = samples.count >= Int(maxClip)
        var clip: [Float]?
        if ended || (tooLong && speaking) {
            clip = samples
            resetLocked()
        }
        lock.unlock()
        if let clip, !clip.isEmpty { transcribe(clip) }
    }

    private func resetLocked() {
        samples.removeAll(keepingCapacity: true)
        speaking = false
        quietCount = 0
        speechCount = 0
    }

    // MARK: - model

    private func transcribe(_ clip: [Float]) {
        let keywords = self.keywords
        work.async { [weak self] in
            guard let self else { return }
            let text = Self.run(clip, keywords: keywords)
            guard !text.isEmpty else { return }
            self.onText?(text, true)
        }
    }

    private static func run(_ clip: [Float], keywords: String) -> String {
        var buffer = [CChar](repeating: 0, count: 16_384)
        let rc = keywords.withCString { keywordPointer in
            clip.withUnsafeBufferPointer { pcm in
                buffer.withUnsafeMutableBufferPointer { out in
                    needle_transcribe(
                        pcm.baseAddress,
                        Int32(pcm.count),
                        nil,
                        keywordPointer,
                        0,
                        out.baseAddress,
                        Int32(out.count)
                    )
                }
            }
        }
        guard rc >= 0 else {
            Automation.mark("voice: whistle transcribe failed rc=\(rc)")
            return ""
        }
        return parseText(String(cString: buffer))
    }

    /// Seed phrases plus the names of known contacts, so names the acoustic
    /// model has never seen come through. Best-effort: peers() may fail.
    private static func keywordList() async -> String {
        var words = ["idfon"]
        if let peers = try? await DaemonClient().peers() {
            for peer in peers {
                if let name = peer.name, !name.isEmpty, !words.contains(name) {
                    words.append(name)
                }
            }
        }
        return words.joined(separator: "\n")
    }

    private static func parseText(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads and loads `whistle.cact`, returning the byte count on success.
    private static func loadModel() async throws -> Int {
        guard let directory = await SpeechProvisioning.directory(for: .whistle) else {
            throw WhistleError.notProvisioned
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("whistle.cact"))
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let rc = data.withUnsafeBytes { raw -> Int32 in
                    needle_load(raw.bindMemory(to: UInt8.self).baseAddress, UInt64(data.count))
                }
                if rc < 0 {
                    let message = needle_last_error().map { String(cString: $0) } ?? "unknown"
                    continuation.resume(throwing: WhistleError.load(message))
                } else {
                    continuation.resume(returning: data.count)
                }
            }
        }
    }

    // MARK: - gate

    private var isGated: Bool {
        lock.lock(); defer { lock.unlock() }
        return gated
    }

    private func setGated(_ value: Bool) {
        lock.lock(); gated = value; lock.unlock()
    }
}
