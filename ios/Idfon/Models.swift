import Foundation

/// How an incoming call is presented for one channel
/// (docs/ui-design-notes.md §6, docs/protocol.md). Bar is the interim
/// default.
///
/// Decoded leniently: an unrecognized wire value resolves to `.bar` rather
/// than throwing, so a future daemon mode iOS does not know never breaks
/// decoding of the whole `peers` array.
enum IncomingCallMode: String, Decodable {
    case bar = "bar"
    case callKit = "call_kit"

    var wireValue: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(IncomingCallMode.init(rawValue:)) ?? .bar
    }
}

struct IdentityInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let active: Bool

    var displayName: String { active ? "\(name) (active)" : name }
}

struct Room: Decodable, Identifiable, Hashable {
    let id: String
    let identity: String
    let name: String?
    let members: [String]
}

struct PeerDevice: Decodable, Hashable {
    let endpointId: String
    let endpointAddr: String?
    let label: String?
    let deviceClass: String?
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case label, capabilities
        case endpointId = "endpoint_id"
        case endpointAddr = "endpoint_addr"
        case deviceClass = "device_class"
    }
}

struct Peer: Decodable, Identifiable {
    let id: String
    let name: String?
    let endpointId: String?
    let devices: [PeerDevice]
    let aliases: [String]?
    let callMode: IncomingCallMode?

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, devices
        case endpointId = "endpoint_id"
        case callMode = "call_mode"
    }

    init(id: String, name: String?, endpointId: String?, aliases: [String]?, callMode: IncomingCallMode?, devices: [PeerDevice] = []) {
        self.id = id
        self.name = name
        self.endpointId = endpointId
        self.aliases = aliases
        self.callMode = callMode
        self.devices = devices
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        endpointId = try values.decodeIfPresent(String.self, forKey: .endpointId)
        devices = try values.decodeIfPresent([PeerDevice].self, forKey: .devices) ?? []
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases)
        callMode = try values.decodeIfPresent(IncomingCallMode.self, forKey: .callMode)
    }

    var displayName: String { name ?? id }

    /// Absent or unrecognized `call_mode` resolves to the Bar (interim default).
    var incomingCallMode: IncomingCallMode { callMode ?? .bar }
}

/// The single navigation target used by both direct chats and rooms.
struct Conversation: Identifiable {
    enum Kind {
        case direct(Peer)
        case room(Room)
    }

    let kind: Kind

    init(peer: Peer) { kind = .direct(peer) }
    init(room: Room) { kind = .room(room) }

    var id: String {
        switch kind {
        case .direct(let peer): return peer.id
        case .room(let room): return room.id
        }
    }

    var room: Room? {
        if case .room(let room) = kind { return room }
        return nil
    }

    var peer: Peer? {
        if case .direct(let peer) = kind { return peer }
        return nil
    }

    var title: String {
        switch kind {
        case .direct(let peer): return peer.displayName
        case .room(let room): return room.name?.isEmpty == false ? room.name! : "Room"
        }
    }

    var isRoom: Bool { room != nil }
}

struct Event: Decodable {
    let eventId: String
    let cursor: String
    let type: String
    /// Epoch seconds as a string (daemon Event.timestamp).
    let timestamp: String
    let data: [String: AnyEncodable]

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case cursor, type, timestamp, data
    }

    var messageText: String? { data["text"]?.stringValue }
    var messagePeerId: String? { data["peer_id"]?.stringValue }
    var messageId: String? { data["message_id"]?.stringValue }
    var conversationId: String? { data["conversation"]?.stringValue }
}

enum MessageKind {
    case text(String)
    /// Voice message: blob ticket + duration (ms) for playback UI.
    case recording(ticket: String, durationMs: Int, localURL: URL?)
    /// File transfer: blob ticket + display name/size. `localURL` is set once
    /// the blob has been fetched to local storage (nil until then).
    case file(ticket: String, name: String, sizeBytes: Int, localURL: URL?)

    static let recordingPrefix = "IDFON-RECORDING/1\n"
    static let filePrefix = "IDFON-FILE/1\n"

    /// Parses a message body into plain text or an `IDFON-*/1` envelope.
    /// Envelopes: `IDFON-RECORDING/1` (voice memo), `IDFON-FILE/1` (file).
    static func parse(_ text: String) -> MessageKind {
        if text.hasPrefix(filePrefix) {
            let fields = envelopeFields(text, prefix: filePrefix)
            guard let ticket = fields["ticket"], !ticket.isEmpty else { return .text(text) }
            return .file(ticket: ticket,
                         name: fields["name"] ?? "file",
                         sizeBytes: Int(fields["size"] ?? "") ?? 0,
                         localURL: nil)
        }
        if text.hasPrefix(recordingPrefix) {
            let fields = envelopeFields(text, prefix: recordingPrefix)
            guard let ticket = fields["ticket"], !ticket.isEmpty else { return .text(text) }
            return .recording(ticket: ticket,
                              durationMs: Int(fields["duration_ms"] ?? "") ?? 0,
                              localURL: nil)
        }
        return .text(text)
    }

    /// `key=value` lines after the envelope header; split on the first `=` so
    /// values may contain `=`.
    private static func envelopeFields(_ text: String, prefix: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.dropFirst(prefix.count).split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
    }
}

struct ChatMessage: Identifiable {
    let id: String
    let peerId: String
    /// Mutable so a late fetch can attach the downloaded file (`localURL`).
    var kind: MessageKind
    let outgoing: Bool
    /// Event time for received messages; `Date()` for locally-sent ones.
    /// Nothing renders it yet — Recents ordering will consume it.
    let timestamp: Date
    /// nil is the ordinary 1:1 conversation; a room id scopes group history.
    let conversation: String?

    init(id: String, peerId: String, kind: MessageKind, outgoing: Bool, timestamp: Date, conversation: String? = nil) {
        self.id = id; self.peerId = peerId; self.kind = kind; self.outgoing = outgoing; self.timestamp = timestamp; self.conversation = conversation
    }

    var displayText: String {
        switch kind {
        case .text(let text): return text
        case .recording: return "Voice message"
        case .file(_, let name, _, _): return name
        }
    }
}

extension AnyEncodable {
    var stringValue: String? { value as? String }
    var boolValue: Bool? { value as? Bool }
    var intValue: Int? { value as? Int }
}
