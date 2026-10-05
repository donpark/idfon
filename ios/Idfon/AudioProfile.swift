import Foundation

enum ContactAudioProfile: String, CaseIterable {
    case opus48k
    case pcm24k

    var codec: String { self == .pcm24k ? "pcm" : "opus" }
    var sampleRate: Int { self == .pcm24k ? 24_000 : 48_000 }
    var title: String { self == .pcm24k ? "PCM · 24 kHz (voice agent)" : "Opus · 48 kHz (default)" }
}

enum ContactAudioProfiles {
    /// The live-call codec is the holder's signed fact (`voice.audio`), not a
    /// manual per-contact choice: `pcm24k` selects PCM, anything else (or a
    /// legacy ticket with no block) selects Opus. Deriving it here keeps the
    /// media session, the dial decision, and the invite in agreement.
    static func profile(for peerID: String) -> ContactAudioProfile {
        CapabilityTickets.voiceRoute(for: peerID)?.audio == "pcm24k" ? .pcm24k : .opus48k
    }
}
