import Foundation
import AVFAudio

/// Shell-side voice-message recorder: consumes the single microphone source
/// (`AudioIO`) and writes the contact-profile format (16 kHz mono s16 WAV),
/// then hands the file to the daemon as a blob + `IDFON-RECORDING/1` envelope.
///
/// It owns no `AVAudioEngine` or `AVAudioRecorder` and never configures the
/// session — `AudioIO` does. It is just an `AudioCaptureObserver` that writes
/// the buffers it receives.
final class VoiceMemo: AudioCaptureObserver {
    private var file: AVAudioFile?
    private(set) var fileURL: URL?
    private(set) var duration: TimeInterval = 0
    private var framesWritten: AVAudioFramePosition = 0

    /// Live amplitude 0...1 while recording, computed from the captured buffers.
    var onAmplitude: ((Float) -> Void)?
    /// Injected for tests; the app uses the single real microphone source.
    private let source: AudioSource

    private static let sampleRate = 16_000.0

    init(source: AudioSource = AudioIO.shared) {
        self.source = source
    }

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func start() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memo-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.file = file
        self.fileURL = url
        self.framesWritten = 0
        AudioIO.shared.start(profile: .recording)
        source.addCaptureObserver(self)
        return url
    }

    /// Stops and returns (fileURL, duration seconds).
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard file != nil, let url = fileURL else { return nil }
        source.removeCaptureObserver(self)
        AudioIO.shared.stop()
        duration = Double(framesWritten) / Self.sampleRate
        self.file = nil   // releases AVAudioFile, flushing the WAV to disk
        self.fileURL = nil
        onAmplitude?(0)
        return (url, duration)
    }

    func discard() {
        let url = fileURL
        _ = stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        duration = 0
    }

    deinit {
        source.removeCaptureObserver(self)
    }

    // MARK: - AudioCaptureObserver

    func audioCapture(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        reportAmplitude(buffer)
        guard let file,
              let output = AudioIO.convert(buffer, to: file.processingFormat)
        else { return }
        try? file.write(from: output)
        framesWritten += AVAudioFramePosition(output.frameLength)
    }

    private func reportAmplitude(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum = 0.0
        for index in 0..<frames {
            let sample = Double(channel[index])
            sum += sample * sample
        }
        let rms = (sum / Double(frames)).squareRoot()
        onAmplitude?(Float(min(rms * 12, 1)))
    }

    /// Downsamples a wav file into normalized amplitudes for a static waveform.
    /// nonisolated: called from detached decode tasks.
    nonisolated static func amplitudes(url: URL, count: Int = 64) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return .init(repeating: 0, count: count) }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return .init(repeating: 0, count: count)
        }
        try? file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else { return .init(repeating: 0, count: count) }

        var result = [Float](repeating: 0, count: count)
        let chunk = Int(buffer.frameLength) / max(count, 1)
        guard chunk > 0 else { return result }
        var peak: Float = 0.001
        for i in 0..<count {
            var maxSample: Float = 0
            for j in 0..<chunk {
                maxSample = max(maxSample, abs(data[i * chunk + j]))
            }
            result[i] = maxSample
            peak = max(peak, maxSample)
        }
        return result.map { $0 / peak }
    }
}