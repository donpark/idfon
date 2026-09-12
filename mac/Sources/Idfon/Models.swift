import Foundation

struct Peer: Decodable, Identifiable, Hashable {
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

struct IdentityInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let active: Bool

    var displayName: String { active ? "\(name) (active)" : name }
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
    case recording(ticket: String, durationMs: Int)
    /// File transfer (§5): blob ticket + display name/size. The downloaded file
    /// lives in `ChatStore.fileURLs[ticket]`.
    case file(ticket: String, name: String, sizeBytes: Int)

    static let recordingPrefix = "IDFON-RECORDING/1\n"
    static let filePrefix = "IDFON-FILE/1\n"

    /// Parses a message body into plain text or an `IDFON-*/1` envelope.
    /// Kept here (not in `ChatStore`) so it stays Foundation-only and testable
    /// by `mac/Checks/MessageKindParseCheck`.
    static func parse(_ text: String) -> MessageKind {
        if text.hasPrefix(filePrefix) {
            let fields = envelopeFields(text, prefix: filePrefix)
            guard let ticket = fields["ticket"], !ticket.isEmpty else { return .text(text) }
            return .file(ticket: ticket,
                         name: fields["name"] ?? "file",
                         sizeBytes: Int(fields["size"] ?? "") ?? 0)
        }
        guard text.hasPrefix(recordingPrefix) else { return .text(text) }
        let fields = envelopeFields(text, prefix: recordingPrefix)
        guard let ticket = fields["ticket"], !ticket.isEmpty else { return .text(text) }
        return .recording(ticket: ticket, durationMs: Int(fields["duration_ms"] ?? "") ?? 0)
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
    /// Mutable so late state can be attached (mirrors `updateMessage`).
    var kind: MessageKind
    let outgoing: Bool
    /// Outgoing delivery state: "Sending" / "Sent" / "Failed" / nil (incoming).
    var status: String?
    /// Event time for received messages; `Date()` for locally-sent ones.
    /// Recents ordering consumes it.
    var timestamp: Date = Date()

    var displayText: String {
        switch kind {
        case .text(let text): return text
        case .recording: return "Voice message"
        case .file(_, let name, _): return name
        }
    }
}

extension AnyEncodable {
    var stringValue: String? { value as? String }
    var boolValue: Bool? { value as? Bool }
    var intValue: Int? { value as? Int }
}