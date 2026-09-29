import Foundation

/// Mirrors `crates/idfon-protocol/src/artifacts.rs`. Artifacts and references
/// travel as `IDFON-ARTIFACT/1` / `IDFON-REF/1` message-text envelopes, so a
/// peer that does not know them still sees plain text.

enum ArtifactKind: String, Codable, Equatable {
    case document, image, audio, video, data, html, live

    var glyph: String {
        switch self {
        case .document: return "doc.text"
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .data: return "curlybraces"
        case .html: return "globe"
        case .live: return "dot.radiowaves.left.and.right"
        }
    }
}

struct Artifact: Codable, Equatable {
    let artifactId: String
    let kind: ArtifactKind
    let mime: String
    let title: String
    let sizeBytes: UInt64
    let blobTicket: String?
    let sourceMessageId: String?
    let conversation: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case kind, mime, title, conversation
        case artifactId = "artifact_id"
        case sizeBytes = "size_bytes"
        case blobTicket = "blob_ticket"
        case sourceMessageId = "source_message_id"
        case createdAt = "created_at"
    }
}

/// A selection inside an artifact; geometry is normalized to `[0, 1]`.
enum ArtifactSelector: Codable, Equatable {
    case whole
    case text(start: UInt64, end: UInt64, quote: String?)
    case region(x: Double, y: Double, width: Double, height: Double, page: UInt32?)
    case timeRange(startMs: UInt64, endMs: UInt64)
    case jsonPointer(String)
    case element(String)

    private enum Kind: String, Codable {
        case whole, text, region, time_range, json_pointer, element
    }

    private enum CodingKeys: String, CodingKey {
        case type, start, end, quote, x, y, width, height, page, pointer, path
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .whole:
            self = .whole
        case .text:
            self = .text(
                start: try container.decode(UInt64.self, forKey: .start),
                end: try container.decode(UInt64.self, forKey: .end),
                quote: try container.decodeIfPresent(String.self, forKey: .quote))
        case .region:
            self = .region(
                x: try container.decode(Double.self, forKey: .x),
                y: try container.decode(Double.self, forKey: .y),
                width: try container.decode(Double.self, forKey: .width),
                height: try container.decode(Double.self, forKey: .height),
                page: try container.decodeIfPresent(UInt32.self, forKey: .page))
        case .time_range:
            self = .timeRange(
                startMs: try container.decode(UInt64.self, forKey: .startMs),
                endMs: try container.decode(UInt64.self, forKey: .endMs))
        case .json_pointer:
            self = .jsonPointer(try container.decode(String.self, forKey: .pointer))
        case .element:
            self = .element(try container.decode(String.self, forKey: .path))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .whole:
            try container.encode(Kind.whole, forKey: .type)
        case .text(let start, let end, let quote):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            try container.encodeIfPresent(quote, forKey: .quote)
        case .region(let x, let y, let width, let height, let page):
            try container.encode(Kind.region, forKey: .type)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encodeIfPresent(page, forKey: .page)
        case .timeRange(let startMs, let endMs):
            try container.encode(Kind.time_range, forKey: .type)
            try container.encode(startMs, forKey: .startMs)
            try container.encode(endMs, forKey: .endMs)
        case .jsonPointer(let pointer):
            try container.encode(Kind.json_pointer, forKey: .type)
            try container.encode(pointer, forKey: .pointer)
        case .element(let path):
            try container.encode(Kind.element, forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}

struct ArtifactRef: Codable, Equatable {
    let artifactId: String
    let selector: ArtifactSelector
    /// Content address, so a reference is self-contained for the consumer.
    let blobTicket: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case selector, note
        case artifactId = "artifact_id"
        case blobTicket = "blob_ticket"
    }
}

/// A user turn that asks about one or more artifact selections.
struct MessageReference: Codable, Equatable {
    let text: String
    let refs: [ArtifactRef]
}

enum ArtifactEnvelope {
    static let artifactPrefix = "IDFON-ARTIFACT/1\n"
    static let referencePrefix = "IDFON-REF/1\n"

    static func decodeArtifact(_ text: String) -> Artifact? {
        guard text.hasPrefix(artifactPrefix) else { return nil }
        let body = String(text.dropFirst(artifactPrefix.count))
        return try? JSONDecoder().decode(Artifact.self, from: Data(body.utf8))
    }

    static func decodeReference(_ text: String) -> MessageReference? {
        guard text.hasPrefix(referencePrefix) else { return nil }
        let body = String(text.dropFirst(referencePrefix.count))
        return try? JSONDecoder().decode(MessageReference.self, from: Data(body.utf8))
    }

    static func encodeArtifact(_ artifact: Artifact) -> String? {
        guard let data = try? JSONEncoder().encode(artifact) else { return nil }
        return artifactPrefix + String(decoding: data, as: UTF8.self)
    }

    static func encodeReference(_ reference: MessageReference) -> String? {
        guard let data = try? JSONEncoder().encode(reference) else { return nil }
        return referencePrefix + String(decoding: data, as: UTF8.self)
    }
}
