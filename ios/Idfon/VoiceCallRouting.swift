import Foundation

/// One selectable voice engine, from the agent's `idfon.json` catalog
/// (`voice.options`). `full-duplex` options occupy both slots (see
/// `ContactVoiceSelection`).
struct VoiceOption: Equatable {
    enum Kind: String {
        case stt
        case tts
        case fullDuplex = "full-duplex"
    }

    enum Side: String {
        case server
        case client
    }

    let id: String
    let kind: Kind
    let label: String
    let side: Side
    let backend: String?
    let model: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let rawKind = json["kind"] as? String,
              let kind = Kind(rawValue: rawKind),
              let label = json["label"] as? String else { return nil }
        self.id = id
        self.kind = kind
        self.label = label
        self.side = (json["side"] as? String).flatMap(Side.init(rawValue:)) ?? .server
        self.backend = json["backend"] as? String
        self.model = json["model"] as? String
    }

    /// A full-duplex option fills both slots; selecting it in either picker
    /// sets the other too.
    var fillsBothSlots: Bool { kind == .fullDuplex }
}

/// The agent's `idfon.json` voice catalog, fetched over the loopback gateway
/// (`idfon://<peer>/idfon.json`) and cached for the process. The resource is
/// fetched on demand, so it stays fresh without re-pairing and never bloats the
/// signed ticket.
enum VoiceCatalog {
    private static var cache: [String: [VoiceOption]] = [:]

    /// The contact's options, or `[]` when the agent advertises none (older
    /// agent, unreachable) — the caller then falls back to the signed route.
    static func options(for peerID: String, client: DaemonClient) async -> [VoiceOption] {
        if let cached = cache[peerID] { return cached }
        guard let data = try? await client.fetchRemoteResource(account: peerID, path: "/idfon.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voice = root["voice"] as? [String: Any],
              let raw = voice["options"] as? [[String: Any]] else {
            return []
        }
        let options = raw.compactMap(VoiceOption.init(json:))
        cache[peerID] = options
        return options
    }

    static func invalidate(for peerID: String) { cache.removeValue(forKey: peerID) }
}

/// Per-contact STT/TTS option ids chosen from the agent's catalog. Stored like
/// the audio profile: UserDefaults keyed by peer id, no server state.
enum ContactVoiceSelection {
    private static let key = "idfon.voice-selection"

    static func selection(for peerID: String) -> (stt: String?, tts: String?) {
        let table = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        let entry = table[peerID] ?? [:]
        return (entry["stt"], entry["tts"])
    }

    static func set(stt: String?, tts: String?, for peerID: String) {
        var table = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        var entry = table[peerID] ?? [:]
        if let stt { entry["stt"] = stt } else { entry.removeValue(forKey: "stt") }
        if let tts { entry["tts"] = tts } else { entry.removeValue(forKey: "tts") }
        if entry.isEmpty { table.removeValue(forKey: peerID) } else { table[peerID] = entry }
        UserDefaults.standard.set(table, forKey: key)
    }

    static func remove(for peerID: String) {
        var table = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        table.removeValue(forKey: peerID)
        UserDefaults.standard.set(table, forKey: key)
    }

    /// The `stt=`/`tts=` lines for a live-call invite, or `""` when unset.
    static func inviteLines(for peerID: String) -> String {
        let (stt, tts) = selection(for: peerID)
        var lines = ""
        if let stt { lines += "\nstt=\(stt)" }
        if let tts { lines += "\ntts=\(tts)" }
        return lines
    }
}

/// Per-contact on-device engine choice, used when the call runs the client
/// cascade. Absent = the app's global default (`SpeechEngines`). Stored as raw
/// backend names so this file stays Foundation-only (no AVFoundation/ML deps);
/// the call path resolves them to `AsrBackend`/`TtsBackend`.
enum ContactOnDeviceEngines {
    private static let key = "idfon.on-device-engines"

    static func asr(for peerID: String) -> String? { table()[peerID]?["asr"] }
    static func tts(for peerID: String) -> String? { table()[peerID]?["tts"] }

    static func set(asr: String?, tts: String?, for peerID: String) {
        var next = table()
        var entry = next[peerID] ?? [:]
        if let asr { entry["asr"] = asr } else { entry.removeValue(forKey: "asr") }
        if let tts { entry["tts"] = tts } else { entry.removeValue(forKey: "tts") }
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

/// What a call actually becomes once the per-contact selection and the signed
/// route are both known. Resolved by `VoiceCallRouting.decide`, a pure function
/// so the branch is testable without a daemon or a UI framework.
enum VoiceCallDecision: Equatable {
    /// Client cascade: on-device STT/TTS, text turns to the agent.
    case onDevice
    /// Dial the holder's live session (native-duplex / server-cascade / hybrid).
    /// The per-contact selection rides the invite; the holder resolves it.
    case live(VoiceRoute?)
    /// A separate voice agent speaks/renders for the target.
    case delegated(VoiceRoute)
    /// Ordinary audio/video call.
    case classic
}

enum VoiceCallRouting {
    /// Resolve the call plan from the per-contact selection (option ids from
    /// the catalog), the signed route, and the legacy heuristic.
    static func decide(selection: (stt: String?, tts: String?),
                       catalog: [VoiceOption],
                       signed: VoiceRoute?,
                       legacyRemote: Bool) -> VoiceCallDecision {
        let chosen = [selection.stt, selection.tts]
            .compactMap { $0 }
            .compactMap { id in catalog.first { $0.id == id } }
        if !chosen.isEmpty {
            // Any server/full-duplex option means the holder terminates audio;
            // an all-client selection is a client cascade.
            let remote = chosen.contains { $0.fillsBothSlots || $0.side == .server }
            return remote ? .live(signed) : .onDevice
        }
        guard let signed else {
            return legacyRemote ? .live(nil) : .classic
        }
        switch signed.mode {
        case .clientCascade:
            return .onDevice
        case .nativeDuplex, .serverCascade:
            return .live(signed)
        case .delegated:
            return .delegated(signed)
        }
    }
}

extension VoiceRoute {
    /// One-line description of the holder's advertisement, for the contact
    /// screen caption.
    var callSummary: String {
        switch mode {
        case .nativeDuplex:
            return model.map { "Holder runs \($0) (full-duplex, remote)" }
                ?? "Holder runs a full-duplex model (remote)"
        case .serverCascade:
            return "Holder runs the server cascade (remote STT + TTS)"
        case .clientCascade:
            return "Agent speaks text; this device supplies STT + TTS"
        case .delegated:
            return "Calls route to a separate voice agent"
        }
    }
}
