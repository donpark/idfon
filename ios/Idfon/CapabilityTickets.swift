import Foundation

/// Peer-scoped capability tickets minted out-of-band by the receiving side.
///
/// A holder that gates ingress (the Eve agent's `eve-idfon`) rejects a
/// message with no holder-signed, subject-bound `message.receive` ticket. An
/// ordinary idfon peer only needs a local grant, so a ticket is optional: when
/// one is stored for the target peer it is attached to `message.send` and
/// otherwise the daemon's grant path applies unchanged.
///
/// A ticket is an opaque `rcan` delegation token (base32). Provisioning is
/// operator-driven — only the holder can sign for itself: `eve-idfon ticket
/// --subject <ios-peer-id>` prints the token, and `-pair-ticket
/// <agent-peer-id> <token|file>` (AppDelegate) stores it here, keyed by the
/// peer id that `sendText` passes as `to` (the `id` field of the `-pair`
/// EndpointAddr JSON). See docs/ios-architecture.md.
enum CapabilityTickets {
    private static let defaultsKey = "idfon.capabilityTickets"

    /// The ticket for `peer`, ready for the `capability_ticket` param of
    /// `message.send`, or nil when none has been provisioned.
    static func ticket(for peer: String) -> AnyEncodable? {
        table()[peer].map { AnyEncodable($0) }
    }

    /// Persist a holder-issued ticket token for `peer`. Rejects anything that
    /// is not a readable `rcan` token; returns false on rejection.
    @discardableResult
    static func store(_ token: String, for peer: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CapabilityTicketToken.parse(trimmed) != nil else { return false }
        var next = table()
        next[peer] = trimmed
        UserDefaults.standard.set(next, forKey: defaultsKey)
        return true
    }

    static func remove(for peer: String) {
        var next = table()
        next.removeValue(forKey: peer)
        UserDefaults.standard.set(next, forKey: defaultsKey)
    }

    /// Whether a holder-issued ticket is stored for `peer`. Distinguishes an
    /// agent/holder contact (even one whose ticket carries no `voice` block)
    /// from an ordinary peer, so the call resolver picks the client cascade
    /// instead of the silent video-call fallback.
    static func hasTicket(for peer: String) -> Bool { table()[peer] != nil }

    /// The stored token (e.g. as ring auth for the edge's `/_push/*` routes),
    /// or nil when none has been provisioned.
    static func rawTicket(for peer: String) -> String? { table()[peer] }

    private static func table() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    /// Voice routing the target's holder signed into its capability ticket, or
    /// nil for a ticket with no `voice` block (callers fall back to the old
    /// name/profile heuristic).
    static func voiceRoute(for peer: String) -> VoiceRoute? {
        guard let token = table()[peer],
              let voice = CapabilityTicketToken.parse(token)?.document["voice"] as? [String: Any],
              let rawMode = voice["mode"] as? String,
              let mode = VoiceRoute.Mode(rawValue: rawMode) else { return nil }
        let delegate = voice["delegate"] as? [String: Any]
        func jsonString(_ value: Any?) -> String? {
            guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return VoiceRoute(
            mode: mode,
            audio: voice["audio"] as? String,
            model: voice["model"] as? String,
            delegatePeerId: delegate?["peer_id"] as? String,
            delegateContact: jsonString(delegate?["contact"]),
            // The delegate's own ticket rides as a token string.
            delegateTicket: delegate?["ticket"] as? String,
            stt: (voice["stt"] as? String).flatMap(VoiceHalf.init(rawValue:)),
            tts: (voice["tts"] as? String).flatMap(VoiceHalf.init(rawValue:)))
    }
}

/// Which side owns one half of the speech pipeline.
enum VoiceHalf: String {
    case server
    case client
}

/// Holder-signed voice routing (`capability_ticket.voice`).
struct VoiceRoute: Equatable {
    enum Mode: String {
        /// The target's holder terminates audio with a full-duplex model session.
        case nativeDuplex = "native-duplex"
        /// The target's holder terminates audio with the server-side cascade.
        case serverCascade = "server-cascade"
        /// The target speaks text; this client supplies on-device STT/TTS.
        case clientCascade = "client-cascade"
        /// A separate voice agent speaks/renders for the target.
        case delegated
        /// One-way: the holder plays audio and never listens (a radio station).
        case broadcast = "broadcast"
    }

    let mode: Mode
    let audio: String?
    let model: String?
    /// Delegate peer id when `mode == .delegated`.
    let delegatePeerId: String?
    /// Delegate endpoint address JSON when `mode == .delegated`.
    let delegateContact: String?
    /// Delegate capability ticket token when `mode == .delegated`.
    let delegateTicket: String?
    /// Which side runs STT/TTS; nil = the mode's default.
    let stt: VoiceHalf?
    let tts: VoiceHalf?

    /// Effective STT ownership, defaulting by mode.
    var sttSide: VoiceHalf { stt ?? (mode == .clientCascade ? .client : .server) }
    /// Effective TTS ownership, defaulting by mode.
    var ttsSide: VoiceHalf { tts ?? (mode == .clientCascade ? .client : .server) }

    /// True when the holder runs a live session but the caller supplies one half.
    var isHybrid: Bool {
        mode != .delegated && (sttSide == .client || ttsSide == .client)
    }
}
