import CryptoKit
import Foundation

/// Deterministic CallKit call identity from an invite ticket
/// (docs/callkit-integration.md P1).
///
/// The same invite re-delivered maps to the same `CXProvider` call, so a
/// redelivery cannot double-ring and the ghost-call rule can dedupe. Tickets
/// are unique per publish, so distinct calls never collide.
enum CallUUID {
    static func from(ticket: String) -> UUID {
        let digest = SHA256.hash(data: Data(ticket.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: bytes.withUnsafeBytes { $0.load(as: uuid_t.self) })
    }
}
