import Foundation

/// How an incoming call is presented for one connection
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

struct Peer: Decodable, Identifiable {
    let id: String
    let name: String?
    let endpointId: String?
    let aliases: [String]?
    let callMode: IncomingCallMode?

    enum CodingKeys: String, CodingKey {
        case id, name, aliases
        case endpointId = "endpoint_id"
        case callMode = "call_mode"
    }

    var displayName: String { name ?? id }

    /// Absent or unrecognized `call_mode` resolves to the Bar (interim default).
    var incomingCallMode: IncomingCallMode { callMode ?? .bar }
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
}

enum MessageKind {
    case text(String)
    /// Voice message: blob ticket + duration (ms) for playback UI.
    case recording(ticket: String, durationMs: Int, localURL: URL?)
}

struct ChatMessage: Identifiable {
    let id: String
    let peerId: String
    let kind: MessageKind
    let outgoing: Bool
    /// Event time for received messages; `Date()` for locally-sent ones.
    /// Nothing renders it yet — Recents ordering will consume it.
    let timestamp: Date
}

extension AnyEncodable {
    var stringValue: String? { value as? String }
    var boolValue: Bool? { value as? Bool }
    var intValue: Int? { value as? Int }
}
