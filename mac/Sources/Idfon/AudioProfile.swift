import Foundation

enum ContactAudioProfile: String, CaseIterable {
    case opus48k
    case pcm24k

    var codec: String { self == .pcm24k ? "pcm" : "opus" }
    var sampleRate: Int { self == .pcm24k ? 24_000 : 48_000 }
    var title: String { self == .pcm24k ? "PCM · 24 kHz (voice agent)" : "Opus · 48 kHz (default)" }
}

enum ContactAudioProfiles {
    private static let key = "idfon.live-audio-profiles"

    static func profile(for peerID: String) -> ContactAudioProfile {
        guard let raw = (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[peerID] else {
            return .opus48k
        }
        return ContactAudioProfile(rawValue: raw) ?? .opus48k
    }

    static func set(_ profile: ContactAudioProfile, for peerID: String) {
        var profiles = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        profiles[peerID] = profile.rawValue
        UserDefaults.standard.set(profiles, forKey: key)
    }
}
