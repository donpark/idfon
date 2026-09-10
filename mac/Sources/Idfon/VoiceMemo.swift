import Foundation
import AVFAudio
import AVFoundation

/// Shell-side voice-message recorder (AVAudioRecorder). Call audio stays
/// daemon-side; voice messages in the composer are recorded here, then handed
/// to the daemon as a blob + IDFON-RECORDING/1 envelope.
///
/// macOS adaptation of the iOS version: no AVAudioSession (doesn't exist on
/// macOS); mic permission comes from AVCaptureDevice instead.
final class VoiceMemo: NSObject {
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?
    private(set) var duration: TimeInterval = 0

    /// Live amplitude 0...1 while recording (recorder metering).
    var onAmplitude: ((Float) -> Void)?
    private var meterTimer: Timer?

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func start() throws -> URL {
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
}