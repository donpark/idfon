import Foundation

enum ContactAudioProfile: String, CaseIterable {
    case opus48k
    /// Opus on the 24 kHz agent plane: same rate the holder's TTS/programme
    /// queue produces, ~1/10 the bandwidth of raw PCM, plus FEC/DRED/PLC.
    case opus24k
    case pcm24k

    var codec: String { self == .pcm24k ? "pcm" : "opus" }
    var sampleRate: Int { self == .opus48k ? 48_000 : 24_000 }
    /// The 24 kHz plane a voice-agent holder terminates audio on.
    var isAgentPlane: Bool { sampleRate == 24_000 }
    var title: String {
        switch self {
        case .opus48k: return "Opus · 48 kHz (default)"
        case .opus24k: return "Opus · 24 kHz (voice agent)"
        case .pcm24k: return "PCM · 24 kHz (voice agent)"
        }
    }
}

enum ContactAudioProfiles {
    private static let key = "idfon.call-audio-codec"

    /// The live-call codec is the holder's signed fact (`voice.audio`):
    /// `pcm24k` selects PCM, anything else (or a legacy ticket with no block)
    /// selects Opus. A per-contact override wins on the agent plane, where the
    /// holder accepts either codec at 24 kHz (docs/voice-agent-modes.md).
    /// Deriving it here keeps the media session, the dial decision, and the
    /// invite in agreement.
    static func profile(for peerID: String) -> ContactAudioProfile {
        let derived = derivedProfile(for: peerID)
        // Only a holder contact has a codec to choose: an on-device agent and
        // an ordinary human peer have no 24 kHz plane.
        guard CapabilityTickets.voiceRoute(for: peerID) != nil,
              let raw = table()[peerID],
              let chosen = ContactAudioProfile(rawValue: raw)
        else { return derived }
        return chosen
    }

    /// The codecs the contact screen offers on the agent plane. The 48 kHz
    /// default belongs to the legacy path and is not a holder codec.
    static var agentChoices: [ContactAudioProfile] { [.pcm24k, .opus24k] }

    /// Persist a choice; the holder's derived codec removes the override.
    static func set(_ profile: ContactAudioProfile, for peerID: String) {
        var next = table()
        if profile == derivedProfile(for: peerID) {
            next.removeValue(forKey: peerID)
        } else {
            next[peerID] = profile.rawValue
        }
        UserDefaults.standard.set(next, forKey: key)
    }

    private static func derivedProfile(for peerID: String) -> ContactAudioProfile {
        CapabilityTickets.voiceRoute(for: peerID)?.audio == "pcm24k" ? .pcm24k : .opus48k
    }

    private static func table() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

/// Which audio modes the panel offers for a contact: the three routes plus
/// the stereo stream. Presence is gated on preferences and capabilities —
/// never on the hardware that happens to be plugged in: the earphone route is
/// assumed available. Shown = the user's allowed set ∩ what the contact is
/// willing to make available.
enum ContactAudioModes {
    /// One offered item: an audio route or the stereo stream.
    enum Token: String, CaseIterable {
        case builtIn, earphone, speaker, stereo
    }

    private static let key = "idfon.call-audio-modes"

    /// Everything offered for `peerID`.
    static func available(for peerID: String) -> Set<Token> {
        userAllowed(for: peerID).intersection(contactAllowed(for: peerID))
    }

    /// The routes the panel shows for `peerID`, in display order. Mute is
    /// always offered: it is the off state, not an offering.
    static func availableRoutes(for peerID: String) -> [CallAudioMode] {
        let allowed = available(for: peerID)
        return CallAudioMode.displayOrder.filter {
            $0 == .mute || allowed.contains(Token(rawValue: $0.rawValue)!)
        }
    }

    /// Whether the stereo stream is on offer for `peerID`.
    static func stereoAllowed(for peerID: String) -> Bool {
        available(for: peerID).contains(.stereo)
    }

    /// The user's allowed modes for `peerID` (no override = all).
    static func userAllowed(for peerID: String) -> Set<Token> {
        guard let raw = table()[peerID] else { return Set(Token.allCases) }
        return Set(raw.compactMap(Token.init(rawValue:)))
    }

    /// Persist the user's allowed modes for `peerID`; nil returns to all.
    static func setUserAllowed(_ tokens: Set<Token>?, for peerID: String) {
        var next = table()
        if let tokens {
            next[peerID] = tokens.map(\.rawValue).sorted()
        } else {
            next.removeValue(forKey: peerID)
        }
        UserDefaults.standard.set(next, forKey: key)
    }

    /// What the contact is willing to make available: a `pcm24k` holder runs
    /// the mono voice-agent plane, so stereo is not on offer there; everything
    /// else is assumed willing.
    static func contactAllowed(for peerID: String) -> Set<Token> {
        // The agent plane is mono at 24 kHz whichever codec carries it, so
        // stereo is not on offer there — an Opus choice must not resurrect it.
        ContactAudioProfiles.profile(for: peerID).isAgentPlane
            ? [.builtIn, .earphone, .speaker]
            : Set(Token.allCases)
    }

    private static func table() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }
}
