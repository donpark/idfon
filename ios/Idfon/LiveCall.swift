import Foundation
import AVFAudio

/// Live-call operations over the daemon's media methods.
///
/// The daemon owns the media pipeline (cpal file source + iroh-live); the
/// shell only triggers dial/answer and manages the audio session. Mic
/// capture is daemon-side work (see docs/native-shells-plan.md) — until it
/// lands, calls stream a bundled WAV file and the callee records to a file.
enum LiveCall {
    /// File the dialer streams (bundled 3s 440Hz sine).
    static var bundledWavPath: String {
        Bundle.main.path(forResource: "hello", ofType: "wav") ?? ""
    }

    /// Where the callee's recording lands (sandbox, daemon-readable since
    /// the daemon runs in-process).
    static var recordingPath: String {
        DaemonPaths.dataDir.appendingPathComponent("last-call.wav").path
    }

    /// Configure the audio session before any daemon audio starts.
    static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
    }

    /// Dial a peer and stream the bundled WAV. Blocks until the callee hangs
    /// up or `seconds` elapses — run off the main actor.
    static func dial(peer: String, seconds: UInt64, client: DaemonClient) async throws {
        activateAudioSession()
        _ = try await client.request(method: "media.live.dial", params: [
            "to": AnyEncodable(peer),
            "file": AnyEncodable(bundledWavPath),
            "seconds": AnyEncodable(Int(seconds)),
        ])
    }

    /// Arm auto-answer: blocks until someone dials, records the call to the
    /// sandbox recording path. Run in a long-lived task; `wait` caps how
    /// long the daemon listens per attempt.
    static func armAutoAnswer(waitSeconds: UInt64, captureSeconds: UInt64, client: DaemonClient) async throws -> String {
        activateAudioSession()
        let result = try await client.request(method: "media.live.answer", params: [
            "wait": AnyEncodable(Int(waitSeconds)),
            "seconds": AnyEncodable(Int(captureSeconds)),
            "out": AnyEncodable(recordingPath),
        ])
        return result?["out"]?.stringValue ?? recordingPath
    }
}
