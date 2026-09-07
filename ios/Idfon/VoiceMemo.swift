import Foundation
import AVFAudio

/// Shell-side voice-message recorder (AVAudioRecorder). Call audio stays
/// daemon-side; voice messages in the composer are recorded here, then handed
/// to the daemon as a blob + IDFON-RECORDING/1 envelope.
final class VoiceMemo: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?
    private(set) var duration: TimeInterval = 0

    /// Live amplitude 0...1 while recording (recorder metering; no engine tap
    /// needed — the recorder is the only input client during a memo).
    var onAmplitude: ((Float) -> Void)?
    private var meterTimer: Timer?

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func start() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memo-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()
        self.recorder = recorder
        fileURL = url

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak recorder] _ in
            guard let recorder else { return }
            recorder.updateMeters()
            // averagePower is dBFS (-160...0); map -35dB..0dB onto 0...1
            let db = recorder.averagePower(forChannel: 0)
            self?.onAmplitude?(Float(pow(10, db / 35)))
        }
        return url
    }

    /// Stops and returns (fileURL, duration seconds).
    func stop() -> (url: URL, duration: TimeInterval)? {
        meterTimer?.invalidate()
        meterTimer = nil
        guard let recorder, let url = fileURL else { return nil }
        duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        return (url, duration)
    }

    /// Downsamples a wav file into normalized amplitudes for a static waveform.
    static func amplitudes(url: URL, count: Int = 64) -> [Float] {
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
