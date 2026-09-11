import Foundation

/// Typed convenience methods over the raw protocol request.
/// Contract: docs/protocol.md.
extension DaemonClient {
    func status() async throws -> (ready: Bool, identityName: String) {
        let result = try await requestWithLaunch(method: "status")
        let ready = result?["ready"]?.boolValue ?? false
        let name = result?["identity"]?["name"]?.stringValue ?? "?"
        return (ready, name)
    }

    /// The identity's connection ticket (endpoint addr JSON) from status.
    /// Raw bytes in the result — decode as UTF-8.
    func statusTicket() async throws -> String {
        guard let raw = try await requestWithLaunch(method: "status"),
              let ticketBytes = raw["ticket"]?.asArray else { return "" }
        let data = Data(ticketBytes.compactMap { enc -> UInt8? in
            guard let v = enc.intValue, v > 0, v < 256 else { return nil }
            return UInt8(v)
        })
        return String(data: data, encoding: .utf8) ?? ""
    }

    func identityId() async throws -> String {
        guard let raw = try await requestWithLaunch(method: "status") else { return "default" }
        return raw["identity"]?["id"]?.stringValue
            ?? raw["identity"]?["name"]?.stringValue
            ?? "default"
    }

    func peers() async throws -> [Peer] {
        guard let list = try await requestWithLaunch(method: "peers")?["peers"]?.asArray else { return [] }
        let data = try JSONEncoder().encode(list)
        return try JSONDecoder().decode([Peer].self, from: data)
    }

    func sendText(to peer: String, _ text: String) async throws {
        _ = try await requestWithLaunch(method: "message.send", params: [
            "to": AnyEncodable(peer),
            "text": AnyEncodable(text),
            "idempotency_key": AnyEncodable("mac-\(UUID().uuidString)"),
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
        guard let list = try await requestWithLaunch(method: "wait", params: params)?["events"]?.asArray else { return [] }
        let data = try JSONEncoder().encode(list)
        return try JSONDecoder().decode([Event].self, from: data)
    }

    /// Adds a peer from its endpoint-addr ticket JSON and grants the chat
    /// capabilities both ways (mirrors the iOS pair automation and the GUI's
    /// Add Connection flow).
    func addConnection(name: String, ticketJSON: String, identity: String) async throws {
        guard let addr = try JSONSerialization.jsonObject(with: Data(ticketJSON.utf8)) as? [String: Any],
              let endpointId = addr["id"] as? String, !endpointId.isEmpty else {
            throw DaemonError.request("invalid endpoint addr JSON (needs an \"id\" field)")
        }
        _ = try await requestWithLaunch(method: "peer.add", params: [
            "id": AnyEncodable(endpointId),
            "name": AnyEncodable(name),
            "endpoint_id": AnyEncodable(endpointId),
            "endpoint_addr": AnyEncodable(ticketJSON),
            "identity": AnyEncodable(identity),
        ])
        for capability in ["message.send", "message.receive", "live_audio_subscribe"] {
            _ = try await requestWithLaunch(method: "access.grant", params: [
                "identity": AnyEncodable(identity),
                "subject": AnyEncodable(endpointId),
                "capability": AnyEncodable(capability),
            ])
        }
    }
}