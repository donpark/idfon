import Foundation

/// Typed convenience methods over the raw protocol request.
/// Contract: docs/protocol.md.
extension DaemonClient {
    func status() throws -> (ready: Bool, identityName: String) {
        let result = try requestWithLaunch(method: "status")
        let ready = result?["ready"]?.boolValue ?? false
        let name = result?["identity"]?["name"]?.stringValue ?? "?"
        return (ready, name)
    }

    /// The identity's connection ticket (endpoint addr JSON) from status.
    /// Raw bytes in the result — decode as UTF-8.
    func statusTicket() throws -> String {
        guard let raw = try requestWithLaunch(method: "status"),
              let ticketBytes = raw["ticket"]?.asArray else { return "" }
        let data = Data(ticketBytes.compactMap { enc -> UInt8? in
            guard let v = enc.intValue, v > 0, v < 256 else { return nil }
            return UInt8(v)
        })
        return String(data: data, encoding: .utf8) ?? ""
    }

    func identityId() throws -> String {
        guard let raw = try requestWithLaunch(method: "status") else { return "default" }
        return raw["identity"]?["id"]?.stringValue
            ?? raw["identity"]?["name"]?.stringValue
            ?? "default"
    }

    func peers() throws -> [Peer] {
        guard let list = try requestWithLaunch(method: "peers")?["peers"]?.asArray else { return [] }
        let data = try JSONEncoder().encode(list)
        return try JSONDecoder().decode([Peer].self, from: data)
    }

    func sendText(to peer: String, _ text: String) throws {
        _ = try requestWithLaunch(method: "message.send", params: [
            "to": AnyEncodable(peer),
            "text": AnyEncodable(text),
            "idempotency_key": AnyEncodable("mac-\(UUID().uuidString)"),
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
        guard let list = try requestWithLaunch(method: "wait", params: params)?["events"]?.asArray else { return [] }
        let data = try JSONEncoder().encode(list)
        return try JSONDecoder().decode([Event].self, from: data)
    }

    /// Adds a peer from its endpoint-addr ticket JSON and grants the chat
    /// capabilities both ways (mirrors the iOS pair automation and the GUI's
    /// Add Connection flow).
    func addConnection(name: String, ticketJSON: String, identity: String) throws {
        guard let addr = try JSONSerialization.jsonObject(with: Data(ticketJSON.utf8)) as? [String: Any],
              let endpointId = addr["id"] as? String, !endpointId.isEmpty else {
            throw DaemonError.request("invalid endpoint addr JSON (needs an \"id\" field)")
        }
        _ = try requestWithLaunch(method: "peer.add", params: [
            "id": AnyEncodable(endpointId),
            "name": AnyEncodable(name),
            "endpoint_id": AnyEncodable(endpointId),
            "endpoint_addr": AnyEncodable(ticketJSON),
            "identity": AnyEncodable(identity),
        ])
        for capability in ["message.send", "message.receive", "live_audio_subscribe"] {
            _ = try requestWithLaunch(method: "access.grant", params: [
                "identity": AnyEncodable(identity),
                "subject": AnyEncodable(endpointId),
                "capability": AnyEncodable(capability),
            ])
        }
    }
}