import Foundation

struct Room: Decodable, Identifiable, Hashable {
    let id: String
    let identity: String
    let name: String?
    let members: [String]
}

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

    /// True when `ref` names this peer: id, name, endpoint id, or alias — the
    /// daemon's peer `ref` rule (docs/protocol.md). Used to resolve
    /// `idfon://<ref>` deeplinks.
    func matches(ref: String) -> Bool {
        id == ref
            || name == ref
            || endpointId == ref
            || (aliases?.contains(ref) ?? false)
    }
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
    var conversationId: String? { data["conversation"]?.stringValue }
}

enum MessageKind {
    case text(String)
    /// Voice message: blob ticket + duration (ms) for playback UI.
    case recording(ticket: String, durationMs: Int)
    /// File transfer (§5): blob ticket + display name/size. The downloaded file
    /// lives in `ChatStore.fileURLs[ticket]`.
    case file(ticket: String, name: String, sizeBytes: Int)
    /// A durable agent output the user can open in a detail screen.
    case artifact(Artifact)
    /// A turn that asks about a selection inside an artifact.
    case reference(MessageReference)

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
        if text.hasPrefix(recordingPrefix) {
            let fields = envelopeFields(text, prefix: recordingPrefix)
            guard let ticket = fields["ticket"], !ticket.isEmpty else { return .text(text) }
            return .recording(ticket: ticket, durationMs: Int(fields["duration_ms"] ?? "") ?? 0)
        }
        if let artifact = ArtifactEnvelope.decodeArtifact(text) { return .artifact(artifact) }
        if let reference = ArtifactEnvelope.decodeReference(text) { return .reference(reference) }
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

/// Splits a message body into human text plus any embedded `IDFON-*/1`
/// envelopes. Agents append envelopes after their reply text (a spoken
/// transcript followed by an `IDFON-DATA/1` or `IDFON-ARTIFACT/1` envelope),
/// so one daemon event can carry both.
enum MessageBody {
    static let prefixes = [
        "IDFON-ARTIFACT/1\n",
        "IDFON-REF/1\n",
        "IDFON-DATA/1\n",
        "IDFON-RECORDING/1\n",
        "IDFON-FILE/1\n",
        "IDFON-LIVE/1\n",
    ]

    static func parse(_ text: String) -> (text: String?, envelopes: [String]) {
        var starts: [String.Index] = []
        var search = text.startIndex
        while let index = firstPrefix(in: text, from: search) {
            starts.append(index)
            search = text.index(after: index)
        }
        guard let first = starts.first else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? nil : text, [])
        }
        let preamble = String(text[text.startIndex..<first])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var envelopes: [String] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : text.endIndex
            envelopes.append(String(text[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (preamble.isEmpty ? nil : preamble, envelopes)
    }

    private static func firstPrefix(in text: String, from search: String.Index) -> String.Index? {
        var best: String.Index?
        for prefix in prefixes {
            if let range = text.range(of: prefix, range: search..<text.endIndex) {
                if best == nil || range.lowerBound < best! { best = range.lowerBound }
            }
        }
        return best
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
    /// nil is the ordinary 1:1 conversation; a room id scopes group history.
    var conversation: String? = nil

    var displayText: String {
        switch kind {
        case .text(let text): return text
        case .recording: return "Voice message"
        case .file(_, let name, _): return name
        case .artifact(let artifact): return artifact.title
        case .reference(let reference):
            return reference.text.isEmpty ? "Asked about an artifact" : reference.text
        }
    }
}

extension AnyEncodable {
    var stringValue: String? { value as? String }
    var boolValue: Bool? { value as? Bool }
    var intValue: Int? { value as? Int }
}