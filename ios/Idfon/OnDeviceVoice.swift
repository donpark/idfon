import AVFAudio
import Foundation
import Speech

/// Apple-native on-device voice provider (P6/A1): `AVSpeechSynthesizer` for TTS
/// and `SFSpeechRecognizer` with `requiresOnDeviceRecognition` for STT. No
/// network, no downloaded model beyond the OS speech assets.
///
/// The provider mirrors the Rust `idfon-voice` seam conceptually; this is the
/// client-side (A1) implementation that can run where memory allows.
final class OnDeviceVoice: NSObject {
    static let shared = OnDeviceVoice()

    private let queue = DispatchQueue(label: "app.idfon.ondevicevoice")
    /// Retained for the duration of a `write`; AVSpeechSynthesizer is async.
    private var synthesizer: AVSpeechSynthesizer?

    private final class SynthesisState {
        var file: AVAudioFile?
        var frames = 0
        var finished = false
    }

    enum VoiceError: LocalizedError {
        case synthesisFailed
        case recognizerUnavailable
        case onDeviceUnavailable
        case denied

        var errorDescription: String? {
            switch self {
            case .synthesisFailed: return "no audio synthesized"
            case .recognizerUnavailable: return "no en-US recognizer"
            case .onDeviceUnavailable: return "on-device recognition unavailable"
            case .denied: return "speech recognition not authorized"
            }
        }
    }

    /// Synthesize `text` to a file entirely on device; reports the frame count.
    func synthesize(
        _ text: String,
        to url: URL,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        let state = SynthesisState()
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        try? FileManager.default.removeItem(at: url)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            self?.queue.async {
                if pcm.frameLength == 0 {
                    // A zero-length buffer ends synthesis.
                    guard !state.finished else { return }
                    state.finished = true
                    self?.synthesizer = nil
                    if state.frames > 0 {
                        completion(.success(state.frames))
                    } else {
                        completion(.failure(VoiceError.synthesisFailed))
                    }
                    return
                }
                if state.file == nil {
                    state.file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings)
                }
                guard let file = state.file else { return }
                do {
                    try file.write(from: pcm)
                    state.frames += Int(pcm.frameLength)
                } catch {
                    NSLog("idfon voice: tts write failed \(error.localizedDescription)")
                }
            }
        }
    }

    /// Transcribe an audio file with on-device recognition only.
    func transcribe(
        url: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                completion(.failure(VoiceError.denied))
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
                completion(.failure(VoiceError.recognizerUnavailable))
                return
            }
            guard recognizer.supportsOnDeviceRecognition else {
                completion(.failure(VoiceError.onDeviceUnavailable))
                return
            }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false

            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let error {
                    done = true
                    completion(.failure(error))
                    return
                }
                if let result, result.isFinal {
                    done = true
                    completion(.success(result.bestTranscription.formattedString))
                }
            }
        }
    }

    /// On-device round trip for `scripts/ios-voice-provider-test.sh`: TTS to a
    /// file, then on-device STT of that file. No microphone or network needed.
    func runSmokeTest() {
        let phrase = "the quick brown fox jumps over the lazy dog"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("idfon-voice-provider-test.wav")
        Automation.mark("voice: start")
        synthesize(phrase, to: url) { [weak self] result in
            switch result {
            case .failure(let error):
                Automation.mark("voice: FAIL tts \(error.localizedDescription)")
                Automation.mark("voice: done")
            case .success(let frames):
                Automation.mark("voice: tts frames=\(frames)")
                self?.transcribe(url: url) { result in
                    switch result {
                    case .failure(let error):
                        Automation.mark("voice: FAIL stt \(error.localizedDescription)")
                    case .success(let text):
                        Automation.mark("voice: stt transcript=\(text)")
                        let normalized = text.lowercased()
                        let ok = normalized.contains("quick brown fox")
                            || normalized.contains("the quick brown")
                        Automation.mark(ok ? "voice: PASS" : "voice: FAIL transcript mismatch")
                    }
                    Automation.mark("voice: done")
                }
            }
        }
    }
}
