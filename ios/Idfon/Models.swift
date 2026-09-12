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
}

extension AnyEncodable {
    var stringValue: String? { value as? String }
    var boolValue: Bool? { value as? Bool }
    var intValue: Int? { value as? Int }
}
