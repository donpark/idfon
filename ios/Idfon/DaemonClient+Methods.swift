import Foundation

/// Typed convenience methods over the raw protocol request.
/// Contract: docs/protocol.md.
extension DaemonClient {
    func status() throws -> (ready: Bool, identityName: String) {
        let result = try request(method: "status")
        let ready = result?["ready"]?.boolValue ?? false
        let name = result?["identity"]?["name"]?.stringValue ?? "?"
        return (ready, name)
    }

    func peers() throws -> [Peer] {
        guard let list = try request(method: "peers")?["peers"]?.asArray else { return [] }
        let data = try JSONEncoder().encode(list)
        return try JSONDecoder().decode([Peer].self, from: data)
    }

    func sendText(to peer: String, _ text: String) throws {
        _ = try request(method: "message.send", params: [
            "to": AnyEncodable(peer),
            "text": AnyEncodable(text),
            "idempotency_key": AnyEncodable("ios-\(UUID().uuidString)"),
        ])
    }

    /// Blocks server-side until one matching event arrives or the timeout
    /// elapses (empty events array on timeout — success, not an error).
    func waitMessages(after cursor: String?, timeoutMs: UInt64 = 30_000) throws -> [Event] {
        var params: [String: AnyEncodable] = [
            "type": AnyEncodable("message.received"),
            "timeout_ms": AnyEncodable(Int(timeoutMs)),
        ]
        if let cursor { params["after"] = AnyEncodable(cursor) }
        guard let list = try request(method: "wait", params: params)?["events"]?.asArray else { return [] }
        let data = try JSONEncoder().encode(list)
        return try JSONDecoder().decode([Event].self, from: data)
    }

    /// Replays retained events after a cursor (foreground reconciliation).
    /// A `cursor_too_old` answer resets the cursor — the caller then restarts
    /// from the oldest retained history.
    func events(after cursor: String?) throws -> [Event] {
        var params: [String: AnyEncodable] = ["type": AnyEncodable("message.received")]
        if let cursor { params["after"] = AnyEncodable(cursor) }
        guard let list = try request(method: "events", params: params)?["events"]?.asArray else { return [] }
        let data = try JSONEncoder().encode(list)
        return try JSONDecoder().decode([Event].self, from: data)
    }
}
