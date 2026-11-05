import Foundation

/// Minimal reader for an `rcan` delegation token (wire v2, base32).
///
/// It does **not** verify the signature — the daemon does that before acting on
/// the ticket. The apps only need the issuer, the subject and the signed ticket
/// document (for voice routing), so this stays a few dozen Foundation lines
/// instead of an ed25519 + postcard implementation.
///
/// Layout: `0x02 | body | signature(64)`, where `body` is
/// `issuer(32) | audience(32) | varint(origin)[+root(32)] | varint(expires)[+varint]
///  | varint(len) | capability`, and the capability is the ticket document as a
/// postcard string (varint length + UTF-8 JSON).
enum CapabilityTicketToken {
    struct Fields {
        let issuer: String
        let audience: String
        let expiresAt: UInt64?
        let document: [String: Any]

        /// The subject endpoint id, or nil for a public/bearer ticket (whose
        /// audience is the issuer itself).
        var subject: String? { document["bearer"] as? Bool == true ? nil : audience }
    }

    static func parse(_ token: String) -> Fields? {
        guard let raw = base32Decode(token), raw.count > 1 + 64 + 64, raw[0] == 2 else { return nil }
        let body = Array(raw[1..<(raw.count - 64)])
        let issuer = hex(body[0..<32])
        let audience = hex(body[32..<64])
        var index = 64
        guard let (origin, afterOrigin) = varint(body, index) else { return nil }
        index = afterOrigin
        if origin == 1 { index += 32 } // re-delegation: the root owner key
        guard index <= body.count, let (expiryTag, afterTag) = varint(body, index) else { return nil }
        index = afterTag
        var expiresAt: UInt64?
        if expiryTag == 1 {
            guard let (value, afterValue) = varint(body, index) else { return nil }
            expiresAt = value
            index = afterValue
        }
        guard let (rawLength, start) = varint(body, index) else { return nil }
        let length = Int(rawLength)
        guard start + length <= body.count else { return nil }
        let capability = Array(body[start..<(start + length)])
        guard let (rawDocLength, docStart) = varint(capability, 0) else { return nil }
        let docLength = Int(rawDocLength)
        guard docStart + docLength <= capability.count,
              let document = try? JSONSerialization.jsonObject(
                  with: Data(capability[docStart..<(docStart + docLength)])) as? [String: Any]
        else { return nil }
        return Fields(issuer: issuer, audience: audience, expiresAt: expiresAt, document: document)
    }

    private static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase base32 (a-z2-7), no padding — the form `rcan` emits.
    private static func base32Decode(_ text: String) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        var out: [UInt8] = []
        for character in text.lowercased() {
            let value: Int
            switch character {
            case "a"..."z": value = Int(character.asciiValue! - Character("a").asciiValue!)
            case "2"..."7": value = Int(character.asciiValue! - Character("2").asciiValue!) + 26
            default: return nil
            }
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                out.append(UInt8((accumulator >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out
    }

    /// Postcard unsigned varint (LEB128, minimal).
    private static func varint(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var scale: UInt64 = 1
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            value += UInt64(byte & 0x7f) * scale
            scale *= 128
            index += 1
            if byte & 0x80 == 0 { return (value, index) }
        }
        return nil
    }
}
