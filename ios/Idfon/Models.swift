import Foundation

struct Peer: Decodable, Identifiable {
    let id: String
    let name: String?
    let endpointId: String?
    let aliases: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, aliases
        case endpointId = "endpoint_id"
    }

    var displayName: String { name ?? id }
}

struct Event: Decodable {
    let eventId: String
    let cursor: String
    let type: String
    let data: [String: AnyEncodable]

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case cursor, type, data
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
}

extension AnyEncodable {
    var stringValue: String? { value as? String }
    var boolValue: Bool? { value as? Bool }
    var intValue: Int? { value as? Int }
}
