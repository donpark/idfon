import Foundation

/// Peer-scoped capability tickets minted out-of-band by the receiving side.
/// Mac port of iOS `CapabilityTickets`: a holder that gates ingress (the Eve
/// agent's `eve-idfon`) rejects a message with no holder-signed,
/// subject-bound `message.receive` ticket. Provisioning is operator-driven —
/// `-pair-ticket <agent-peer-id> <json|file>` (IdfonApp automation) stores it
/// here, keyed by the peer id `sendText` passes as `to`.
enum CapabilityTickets {
    private static let defaultsKey = "idfon.capabilityTickets"

    /// The ticket for `peer` as a JSON object ready for the `capability_ticket`
    /// param of `message.send`, or nil when none has been provisioned.
    static func ticket(for peer: String) -> AnyEncodable? {
        guard let json = table()[peer], let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnyEncodable.self, from: data)
    }

    /// Persist a holder-issued ticket (raw JSON text) for `peer`. Rejects
    /// anything that is not a JSON object; returns false on rejection.
    @discardableResult
    static func store(_ json: String, for peer: String) -> Bool {
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return false }
        var next = table()
        next[peer] = json
        UserDefaults.standard.set(next, forKey: defaultsKey)
        return true
    }

    static func remove(for peer: String) {
        var next = table()
        next.removeValue(forKey: peer)
        UserDefaults.standard.set(next, forKey: defaultsKey)
    }

    /// Whether a holder-issued ticket is stored for `peer`. Distinguishes an
    /// agent/holder contact (even one whose ticket has no `voice` block) from
    /// an ordinary peer, so the call resolver picks the client cascade instead
    /// of the silent video-call fallback.
    static func hasTicket(for peer: String) -> Bool { table()[peer] != nil }

    private static func table() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    /// Voice routing the target's holder signed into its capability ticket, or
    /// nil for a legacy ticket with no `voice` block (callers fall back to the
    /// old name/profile heuristic).
    static func voiceRoute(for peer: String) -> VoiceRoute? {
        guard let json = table()[peer], let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voice = object["voice"] as? [String: Any],
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
            delegateTicket: jsonString(delegate?["ticket"]),
            stt: (voice["stt"] as? String).flatMap(VoiceHalf.init(rawValue:)),
            tts: (voice["tts"] as? String).flatMap(VoiceHalf.init(rawValue:)))
    }
}

/// Holder-signed voice routing (`capability_ticket.voice`).
/// Which side owns one half of the speech pipeline.
enum VoiceHalf: String {
    case server
    case client
}

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
    }

    let mode: Mode
    let audio: String?
    let model: String?
    /// Delegate peer id when `mode == .delegated`.
    let delegatePeerId: String?
    /// Delegate endpoint address JSON when `mode == .delegated`.
    let delegateContact: String?
    /// Delegate capability ticket JSON when `mode == .delegated`.
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
