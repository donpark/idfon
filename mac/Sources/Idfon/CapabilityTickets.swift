import Foundation

/// Peer-scoped capability tickets minted out-of-band by the receiving side.
/// Mac port of iOS `CapabilityTickets`: a holder that gates ingress (the Eve
/// agent's `eve-idfon`) rejects a message with no holder-signed,
/// subject-bound `message.receive` ticket. Provisioning is operator-driven —
/// `-pair-ticket <agent-peer-id> <json|file>` (IdfonApp automation) stores it
/// here, keyed by the peer id `sendText` passes as `to`.
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
