import Foundation

/// Peer-scoped capability tickets minted out-of-band by the receiving side.
///
/// A holder that gates ingress (the Eve agent's `eve-idfon-channel`) rejects a
/// message with no holder-signed, subject-bound `message.receive` ticket. An
/// ordinary idfon peer only needs a local grant, so a ticket is optional: when
/// one is stored for the target peer it is attached to `message.send` and
/// otherwise the daemon's grant path applies unchanged.
///
/// Provisioning is operator-driven — only the holder can sign for itself:
/// `eve-idfon-channel ticket --subject <ios-peer-id>` prints the JSON, and
/// `-pair-ticket <agent-peer-id> <json|file>` (AppDelegate) stores it here,
/// keyed by the peer id that `sendText` passes as `to` (the `id` field of the
/// `-pair` EndpointAddr JSON). See docs/ios-architecture.md.
enum CapabilityTickets {
    private static let defaultsKey = "idfon.capabilityTickets"

    /// The ticket for `peer` as a JSON object ready for the `capability_ticket`
    /// param of `message.send`, or nil when none has been provisioned.
    static func ticket(for peer: String) -> AnyEncodable? {
        guard let json = table()[peer], let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnyEncodable.self, from: data)
    }

    /// Persist a holder-issued ticket (raw JSON text) for `peer`. Rejects
    /// anything that is not a JSON object; returns false on rejection.
    @discardableResult
    static func store(_ json: String, for peer: String) -> Bool {
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return false }
        var next = table()
        next[peer] = json
        UserDefaults.standard.set(next, forKey: defaultsKey)
        return true
    }

    static func remove(for peer: String) {
        var next = table()
        next.removeValue(forKey: peer)
        UserDefaults.standard.set(next, forKey: defaultsKey)
    }

    private static func table() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}
