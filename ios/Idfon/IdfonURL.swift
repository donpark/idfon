import Foundation

/// Addressing for `idfon://` links.
///
/// Grammar (RFC 3986 hierarchical form):
///
///     idfon://<peer-ref>[/path...]   -> .resource(ref:path:)
///     idfon://dial/<peer-ref>        -> .dial(ref:)
///     idfon://videodial/<peer-ref>   -> .videoDial(ref:)
///     idfon://answer                 -> .answer
///
/// `peer-ref` is what the daemon's peer methods accept: peer id, name, alias,
/// or endpoint id (docs/protocol.md). Hosts are case-insensitive per RFC 3986,
/// so reserved verbs match case-insensitively; resource refs keep their case so
/// mixed-case names and aliases still resolve. A 64-char hex endpoint id or the
/// derived account handle `blake3(account_id)` is normalized to lowercase (both
/// are lowercase hex already, and both resolve through `Peer.matches(ref:)`).
/// Base32/z-base-32 hosts
/// are deliberately not accepted: those encodings exist for DNS labels, and a
/// deeplink resolves the ref against the local peer list, never through DNS.
enum IdfonURL: Equatable {
    /// A resource on a peer: `idfon://<ref>/<path>`. `path` excludes the ref.
    case resource(ref: String, path: [String])
    case dial(ref: String)
    case videoDial(ref: String)
    case answer

    static let scheme = "idfon"
    /// Hosts reserved for deeplink verbs; they never name a peer.
    static let reservedVerbs: Set<String> = ["dial", "videodial", "answer"]

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let host = url.host ?? ""
        let path = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if host.isEmpty {
            // No host (`idfon:///dial/<ref>`): the verb lives in the path.
            guard let verb = path.first, let parsed = Self.verb(verb, ref: path.dropFirst().first) else {
                return nil
            }
            self = parsed
        } else if Self.reservedVerbs.contains(host.lowercased()) {
            guard let parsed = Self.verb(host, ref: path.first) else { return nil }
            self = parsed
        } else if Self.isEndpointId(host) {
            self = .resource(ref: host.lowercased(), path: path)
        } else {
            self = .resource(ref: host, path: path)
        }
    }

    private static func verb(_ verb: String, ref: String?) -> IdfonURL? {
        switch verb.lowercased() {
        case "dial": return ref.map { .dial(ref: $0) }
        case "videodial": return ref.map { .videoDial(ref: $0) }
        case "answer": return .answer
        default: return nil
        }
    }

    /// True for a 64-char hex iroh endpoint id or derived account handle.
    static func isEndpointId(_ host: String) -> Bool {
        host.count == 64 && host.allSatisfy(\.isHexDigit)
    }
}
