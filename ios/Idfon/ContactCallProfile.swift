import Foundation

/// What a contact is (human vs agent) and whether the app can place a call to
/// them at all. The contacts list's row Call verb, the chat's call entry, and
/// the chat-open speech prewarm all consult it.
struct ContactCallProfile {
    enum Kind: String, CaseIterable {
        /// An ordinary peer — a person (`voice` false records e.g. a deaf user).
        case human
        /// An agent/holder contact (capability ticket or on-device agent).
        case agent
    }

    var kind: Kind
    var voiceEnabled: Bool
}

/// Per-contact call profile store (UserDefaults, like the other `Contact*`
/// stores). Effective values derive from the signed facts the app already
/// holds; the person screen persists overrides (a human can be deaf, an agent
/// can refuse voice by policy) and stored values win, so an override survives
/// ticket updates.
enum ContactCallProfiles {
    private static let key = "idfon.call-profile"

    static func profile(for peerID: String) -> ContactCallProfile {
        let entry = table()[peerID] ?? [:]
        let onDevice = OnDeviceAgents.shared.agent(forPeerId: peerID) != nil
        // CapabilityTickets.hasTicket distinguishes an agent "even one whose
        // ticket has no `voice` block" from an ordinary peer.
        let ticketed = CapabilityTickets.hasTicket(for: peerID)
        let kind = entry["kind"].flatMap(ContactCallProfile.Kind.init(rawValue:))
            ?? (onDevice || ticketed ? .agent : .human)
        let voiceEnabled: Bool
        if let raw = entry["voice"] {
            voiceEnabled = raw == "on"
        } else if onDevice || !ticketed {
            voiceEnabled = true
        } else {
            // The ticket's `voice` block is the holder's signed answer: no
            // block (legacy ticket, or the agent refusing voice) = not callable.
            voiceEnabled = CapabilityTickets.voiceRoute(for: peerID) != nil
        }
        return ContactCallProfile(kind: kind, voiceEnabled: voiceEnabled)
    }

    /// Callable == takes calls (voice for agents, the classic call for humans).
    static func isCallable(_ peerID: String) -> Bool {
        profile(for: peerID).voiceEnabled
    }

    /// Persist overrides from the person screen; nil returns a field to its
    /// derived default.
    static func set(kind: ContactCallProfile.Kind?, voice: Bool?, for peerID: String) {
        var next = table()
        var entry = next[peerID] ?? [:]
        if let kind { entry["kind"] = kind.rawValue } else { entry.removeValue(forKey: "kind") }
        if let voice { entry["voice"] = voice ? "on" : "off" } else { entry.removeValue(forKey: "voice") }
        if entry.isEmpty { next.removeValue(forKey: peerID) } else { next[peerID] = entry }
        UserDefaults.standard.set(next, forKey: key)
    }

    static func remove(for peerID: String) {
        var next = table()
        next.removeValue(forKey: peerID)
        UserDefaults.standard.set(next, forKey: key)
    }

    private static func table() -> [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
    }
}
