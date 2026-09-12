import Foundation

/// Typed convenience methods over the raw protocol request.
/// Contract: docs/protocol.md.
extension DaemonClient {
    func status() async throws -> (ready: Bool, identityName: String) {
        let result = try await request(method: "status")
        let ready = result?["ready"]?.boolValue ?? false
        let name = result?["identity"]?["name"]?.stringValue ?? "?"
        return (ready, name)
    }

    func peers() async throws -> [Peer] {
        guard let list = try await request(method: "peers")?["peers"]?.asArray else { return [] }
        let data = try JSONEncoder().encode(list)
        return try JSONDecoder().decode([Peer].self, from: data)
    }

    /// Canonical identity id, which is what peer records are keyed by
    /// (`status` reports the identity's name, which may differ).
    func identityId() async throws -> String {
        let raw = try await request(method: "status")
        return raw?["identity"]?["id"]?.stringValue ?? "default"
    }

    /// `peer.update` with only `call_mode`: absent params are left untouched
    /// (docs/protocol.md). Requires the owning identity plus the peer ref.
    func setIncomingCallMode(ref: String, _ mode: IncomingCallMode) async throws {
        let identity = (try? await identityId()) ?? "default"
        _ = try await request(method: "peer.update", params: [
            "ref": AnyEncodable(ref),
            "identity": AnyEncodable(identity),
            "call_mode": AnyEncodable(mode.wireValue),
        ])
    }

    func sendText(to peer: String, _ text: String) async throws {
        _ = try await request(method: "message.send", params: [
            "to": AnyEncodable(peer),
            "text": AnyEncodable(text),
            "idempotency_key": AnyEncodable("ios-\(UUID().uuidString)"),
        ])
    }

    /// Blocks server-side until one matching event arrives or the timeout
    /// elapses (empty events array on timeout — success, not an error).
    func waitMessages(after cursor: String?, timeoutMs: UInt64 = 30_000) async throws -> [Event] {
        var params: [String: AnyEncodable] = [
            "type": AnyEncodable("message.received"),
            "timeout_ms": AnyEncodable(Int(timeoutMs)),
        ]
        if let cursor { params["after"] = AnyEncodable(cursor) }
        guard let list = try await request(method: "wait", params: params)?["events"]?.asArray else { return [] }
        let data = try JSONEncoder().encode(list)
        return try JSONDecoder().decode([Event].self, from: data)
    }

    /// Replays retained events after a cursor (foreground reconciliation).
    /// A `cursor_too_old` answer resets the cursor — the caller then restarts
    /// from the oldest retained history.
    func events(after cursor: String?) async throws -> [Event] {
        var params: [String: AnyEncodable] = ["type": AnyEncodable("message.received")]
        if let cursor { params["after"] = AnyEncodable(cursor) }
        guard let list = try await request(method: "events", params: params)?["events"]?.asArray else { return [] }
        let data = try JSONEncoder().encode(list)
        return try JSONDecoder().decode([Event].self, from: data)
    }
}
