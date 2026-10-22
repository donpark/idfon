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

/// Which audio modes the panel offers for a contact. Presence is gated on
/// preferences and capabilities — never on the hardware that happens to be
/// plugged in: earphone modes are assumed available. Shown = the user's
/// allowed set ∩ what the contact is willing to make available.
enum ContactAudioModes {
    private static let key = "idfon.call-audio-modes"

    /// The modes the panel shows for `peerID`, in display order.
    static func available(for peerID: String) -> [CallAudioMode] {
        let allowed = userAllowed(for: peerID).intersection(contactAllowed(for: peerID))
        return CallAudioMode.displayOrder.filter { allowed.contains($0) }
    }

    /// The user's allowed modes for `peerID` (no override = all).
    static func userAllowed(for peerID: String) -> Set<CallAudioMode> {
        guard let raw = table()[peerID] else { return Set(CallAudioMode.allCases) }
        return Set(raw.compactMap(CallAudioMode.init(rawValue:)))
    }

    /// Persist the user's allowed modes for `peerID`; nil returns to all.
    static func setUserAllowed(_ modes: Set<CallAudioMode>?, for peerID: String) {
        var next = table()
        if let modes {
            next[peerID] = modes.map(\.rawValue).sorted()
        } else {
            next.removeValue(forKey: peerID)
        }
        UserDefaults.standard.set(next, forKey: key)
    }

    /// What the contact is willing to make available: a `pcm24k` holder runs
    /// the mono voice-agent plane, so 2D (stereo) is not on offer there;
    /// everything else is assumed willing.
    static func contactAllowed(for peerID: String) -> Set<CallAudioMode> {
        ContactAudioProfiles.profile(for: peerID) == .pcm24k
            ? [.builtIn, .earphone, .speaker]
            : Set(CallAudioMode.allCases)
    }

    private static func table() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }
}
