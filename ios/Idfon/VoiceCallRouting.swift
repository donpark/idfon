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
    /// The fetch is bounded: a hung gateway must not stall the call decision.
    static func options(for peerID: String, client: IdfonClient,
                        timeout: Duration = .seconds(3)) async -> [VoiceOption] {
        if let cached = cache[peerID] { return cached }
        let data = await withTaskGroup(of: Data?.self) { group in
            group.addTask { try? await client.fetchRemoteResource(account: peerID, path: "/idfon.json") }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let data,
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

/// The menu a contact exposes: `menu.opml` in its `idfon.json` manifest — a
/// holder path (`/menu.opml`) or an http(s) URL. Fetched and cached like the
/// catalog; nil when the contact advertises none (older agent, unreachable),
/// and the call then dials without a selection.
struct ContactMenu {
    let entries: [MenuEntry]
    /// The show the contact chose to play on open; nil = show the menu only.
    let defaultShow: String?
}

enum ContactMenus {
    private static var cache: [String: ContactMenu?] = [:]

    static func menu(for peerID: String, client: IdfonClient) async -> ContactMenu? {
        if let cached = cache[peerID] { return cached }
        let data = await withTaskGroup(of: Data?.self) { group in
            group.addTask { try? await client.fetchRemoteResource(account: peerID, path: "/idfon.json") }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let menu = root["menu"] as? [String: Any],
              let ref = (menu["opml"] as? String)?.trimmingCharacters(in: .whitespaces),
              !ref.isEmpty else {
            cache[peerID] = .some(nil)
            return nil
        }
        guard let document = await fetchOPML(ref, peerID: peerID, client: client)
            .flatMap(MenuDocument.parse), !document.entries.isEmpty else {
            cache[peerID] = .some(nil)
            return nil
        }
        let rawDefault = (root["default"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let surface = ContactMenu(
            entries: document.entries,
            defaultShow: rawDefault?.isEmpty == false ? rawDefault : nil)
        cache[peerID] = .some(surface)
        return surface
    }

    /// A leading slash is a resource on the contact's own holder; anything
    /// else must be an http(s) URL (an online station's public OPML).
    private static func fetchOPML(_ ref: String, peerID: String, client: IdfonClient) async -> Data? {
        if ref.hasPrefix("/") {
            return try? await client.fetchRemoteResource(account: peerID, path: ref)
        }
        guard let url = URL(string: ref), ["http", "https"].contains(url.scheme ?? "") else {
            return nil
        }
        return try? await URLSession.shared.data(from: url).0
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

    static func value(for peerID: String, slot: SpeechSlot) -> String? {
        let selection = selection(for: peerID)
        return slot == .recognition ? selection.stt : selection.tts
    }

    static func set(slot: SpeechSlot, value: String?, for peerID: String) {
        let (stt, tts) = selection(for: peerID)
        set(stt: slot == .recognition ? value : stt,
            tts: slot == .generation ? value : tts, for: peerID)
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

    /// The `stt=`/`tts=` lines for a live-call invite plus an optional caller
    /// context line (`context_b64=`), or `""` when unset. The context is the
    /// active caller-side state the UI applied to this call (e.g. on-device
    /// engines); the holder injects it as untrusted data, never instructions.
    static func inviteLines(for peerID: String, context: String? = nil) -> String {
        let (stt, tts) = selection(for: peerID)
        var lines = ""
        if let stt { lines += "\nstt=\(stt)" }
        if let tts { lines += "\ntts=\(tts)" }
        // A half this device runs on-device is client-owned for this call; tell
        // the holder not to also run it (a per-contact hybrid).
        if ContactOnDeviceEngines.asr(for: peerID) != nil { lines += "\nstt_side=client" }
        if ContactOnDeviceEngines.tts(for: peerID) != nil { lines += "\ntts_side=client" }
        if let context, !context.isEmpty {
            lines += "\ncontext_b64=\(Data(context.utf8).base64EncodedString())"
        }
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

    static func value(for peerID: String, slot: SpeechSlot) -> String? {
        slot == .recognition ? asr(for: peerID) : tts(for: peerID)
    }

    static func set(slot: SpeechSlot, value: String?, for peerID: String) {
        set(asr: slot == .recognition ? value : asr(for: peerID),
            tts: slot == .generation ? value : tts(for: peerID), for: peerID)
    }

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

/// The agent's voice (#202): a per-contact Phonon voice name used to
/// re-synthesize that contact's messages on replay. Absent = the engine
/// default. This is the agent's voice as configured; generating true voices
/// from samples at runtime is the later step (docs/voice-samples.md).
enum ContactVoice {
    private static let key = "idfon.contact-voice"

    static func value(for peerID: String) -> String? {
        table()[peerID]
    }

    static func set(_ value: String?, for peerID: String) {
        var next = table()
        if let value {
            next[peerID] = value
        } else {
            next.removeValue(forKey: peerID)
        }
        UserDefaults.standard.set(next, forKey: key)
    }

    private static func table() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

/// Which half of the speech pipeline a picker controls.
enum SpeechSlot { case recognition, generation }

/// How the voice layer treats the turns of a client-cascade call
/// (`docs/voice-agent-modes.md`). Passive puts nothing in front of the wrapped
/// agent: the turn is the caller's own words. Proxy runs the on-device
/// director first, so it can answer itself, delegate with `voice_forward`, or
/// hold a tool — it costs an on-device turn plus the remote round trip.
///
/// Only client-cascade calls have a caller-side director to put in front (a
/// holder-side/live call terminates audio on the holder), so this setting is
/// read where the call session starts, not where the route is resolved.
enum VoiceTurnMode: String, CaseIterable, Equatable {
    case passive
    case proxy

    var title: String { self == .proxy ? "Proxy" : "Passive" }
}

/// Per-contact turn mode. Stored like the other per-contact voice settings:
/// UserDefaults keyed by peer id, no server state. Absent = passive, the
/// documented default.
enum ContactVoiceTurnModes {
    private static let key = "idfon.voice-turn-mode"

    static func mode(for peerID: String) -> VoiceTurnMode {
        table()[peerID].flatMap(VoiceTurnMode.init(rawValue:)) ?? .passive
    }

    static func set(_ mode: VoiceTurnMode, for peerID: String) {
        var next = table()
        // Passive is the default, so it is stored as absence.
        if mode == .passive { next.removeValue(forKey: peerID) } else { next[peerID] = mode.rawValue }
        UserDefaults.standard.set(next, forKey: key)
    }

    static func remove(for peerID: String) {
        var next = table()
        next.removeValue(forKey: peerID)
        UserDefaults.standard.set(next, forKey: key)
    }

    private static func table() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

/// One entry in a contact's unified Speech picker: an on-device backend or an
/// agent-catalog option. `id` is the store key (backend raw value or option id).
struct SpeechChoice: Equatable {
    enum Store: Equatable { case onDevice, catalog, agentDefault }
    let store: Store
    let id: String
    let title: String
}

/// Unified read/write over the two per-contact stores (`ContactOnDeviceEngines`
/// and `ContactVoiceSelection`) so one Recognition/Generation picker spans both.
/// When there is no stored pick, the signed route owns the default engine.
enum ContactSpeech {
    static func defaultChoice(slot: SpeechSlot, route: VoiceRoute?, catalog: [VoiceOption],
                              localId: String, localTitle: String) -> SpeechChoice {
        let remote = slot == .recognition ? route?.sttSide == .server : route?.ttsSide == .server
        guard remote else { return SpeechChoice(store: .onDevice, id: localId, title: localTitle) }
        let kind: VoiceOption.Kind = slot == .recognition ? .stt : .tts
        let defaults = catalog.filter { ($0.kind == kind || $0.fillsBothSlots) && $0.side == .server }
        let title = defaults.count == 1 ? "Agent default — \(defaults[0].label)" : "Agent default (remote)"
        return SpeechChoice(store: .agentDefault, id: "agent-default", title: title)
    }

    static func stored(for peerID: String, slot: SpeechSlot) -> SpeechChoice? {
        if let backend = ContactOnDeviceEngines.value(for: peerID, slot: slot) {
            return SpeechChoice(store: .onDevice, id: backend, title: "")
        }
        if let id = ContactVoiceSelection.value(for: peerID, slot: slot) {
            return SpeechChoice(store: .catalog, id: id, title: "")
        }
        return nil
    }

    /// Persist `pick` for `slot`, clearing the other store for that half. A
    /// catalog full-duplex option fills both halves. `nil` clears both stores.
    static func set(_ pick: SpeechChoice?, catalog: [VoiceOption], for peerID: String, slot: SpeechSlot) {
        guard let pick else {
            ContactOnDeviceEngines.set(slot: slot, value: nil, for: peerID)
            ContactVoiceSelection.set(slot: slot, value: nil, for: peerID)
            return
        }
        switch pick.store {
        case .agentDefault:
            ContactOnDeviceEngines.set(slot: slot, value: nil, for: peerID)
            ContactVoiceSelection.set(slot: slot, value: nil, for: peerID)
        case .onDevice:
            ContactOnDeviceEngines.set(slot: slot, value: pick.id, for: peerID)
            ContactVoiceSelection.set(slot: slot, value: nil, for: peerID)
        case .catalog:
            ContactOnDeviceEngines.set(slot: slot, value: nil, for: peerID)
            if catalog.first(where: { $0.id == pick.id })?.fillsBothSlots == true {
                for half in [SpeechSlot.recognition, .generation] {
                    ContactVoiceSelection.set(slot: half, value: pick.id, for: peerID)
                    ContactOnDeviceEngines.set(slot: half, value: nil, for: peerID)
                }
            } else {
                ContactVoiceSelection.set(slot: slot, value: pick.id, for: peerID)
            }
        }
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
                       onDevice: (stt: String?, tts: String?) = (nil, nil),
                       catalog: [VoiceOption],
                       signed: VoiceRoute?,
                       holderTicket: Bool,
                       legacyRemote: Bool) -> VoiceCallDecision {
        let chosen = [selection.stt, selection.tts]
            .compactMap { $0 }
            .compactMap { id in catalog.first { $0.id == id } }
        // The picks override the signed half-ownership, so a per-contact hybrid
        // (one on-device half + one server catalog half) reaches the holder as
        // a hybrid instead of silently running both halves itself.
        let resolved = signed?.resolving(selection: selection, onDevice: onDevice, catalog: catalog)
        // An explicit on-device pick is a pick too: without this the picker is a
        // silent no-op on a holder that advertises its own route.
        let hasPick = !chosen.isEmpty || onDevice.stt != nil || onDevice.tts != nil
        // A holder that never terminates media — client cascade, or a ticket
        // with no voice block (that holder's documented default is the
        // cascade) — is a text peer: picks choose the local engines the
        // cascade runs and must never re-route the call into a media session
        // such a holder leaves ringing forever.
        let textOnlyHolder = signed?.mode == .clientCascade || (signed == nil && holderTicket)
        if hasPick && !textOnlyHolder {
            // Any server/full-duplex option means the holder terminates audio;
            // an all-client selection or on-device pick is a client cascade.
            let remote = chosen.contains { $0.fillsBothSlots || $0.side == .server }
            return remote ? .live(resolved) : .onDevice
        }
        guard let signed else {
            // A holder-minted ticket with no `voice` block is an agent whose
            // holder predates voice routing: its documented default is the
            // client cascade. Only a peer with no ticket at all (an ordinary
            // human contact) falls back to the legacy video-call path — and
            // that path can dead-end silently, so it stays the last resort.
            if holderTicket { return .onDevice }
            return legacyRemote ? .live(nil) : .classic
        }
        switch signed.mode {
        case .clientCascade:
            return .onDevice
        case .nativeDuplex, .serverCascade, .broadcast:
            return .live(resolved ?? signed)
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
        case .broadcast:
            return "One-way: the agent plays audio, you listen"
        }
    }

    /// The half(s) this caller runs on-device for `route`, per the signed
    /// route. Empty when the holder runs both or the call is delegated (nothing
    /// caller-side to report). Drives the invite's `context_b64=` line.
    var clientHalves: [SpeechSlot] {
        guard mode != .delegated else { return [] }
        var halves: [SpeechSlot] = []
        if sttSide == .client { halves.append(.recognition) }
        if ttsSide == .client { halves.append(.generation) }
        return halves
    }

    /// Override the signed half-ownership with the contact's picks: an
    /// on-device pick makes that half client-owned; a catalog pick uses its
    /// option side. Halves with no pick keep the signed route's ownership.
    func resolving(selection: (stt: String?, tts: String?),
                   onDevice: (stt: String?, tts: String?),
                   catalog: [VoiceOption]) -> VoiceRoute {
        func half(_ onDevice: String?, _ selected: String?) -> VoiceHalf? {
            if onDevice != nil { return .client }
            guard let selected, let option = catalog.first(where: { $0.id == selected }) else { return nil }
            return option.side == .client ? .client : .server
        }
        return VoiceRoute(
            mode: mode,
            audio: audio,
            model: model,
            delegatePeerId: delegatePeerId,
            delegateContact: delegateContact,
            delegateTicket: delegateTicket,
            stt: half(onDevice.stt, selection.stt) ?? stt,
            tts: half(onDevice.tts, selection.tts) ?? tts)
    }
}
