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

    /// The identity's channel ticket (endpoint addr JSON) from status.
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

    func rooms() async throws -> [Room] {
        guard let list = try await requestWithLaunch(method: "room.list")?["rooms"]?.asArray else { return [] }
        return try JSONDecoder().decode([Room].self, from: JSONEncoder().encode(list))
    }

    func joinRoom(_ room: String, name: String? = nil, members: [String] = []) async throws -> Room {
        var params: [String: AnyEncodable] = ["room": AnyEncodable(room)]
        if let name { params["name"] = AnyEncodable(name) }
        if !members.isEmpty { params["members"] = AnyEncodable(members.map(AnyEncodable.init)) }
        guard let raw = try await requestWithLaunch(method: "room.join", params: params)?["room"] else {
            throw DaemonClient.DaemonError.request("room.join returned no room")
        }
        return try JSONDecoder().decode(Room.self, from: JSONEncoder().encode(raw))
    }

    func createRoom(id: String? = nil, name: String? = nil, members: [String] = []) async throws -> Room {
        var params: [String: AnyEncodable] = [:]
        if let id { params["id"] = AnyEncodable(id) }
        if let name { params["name"] = AnyEncodable(name) }
        if !members.isEmpty { params["members"] = AnyEncodable(members.map(AnyEncodable.init)) }
        guard let raw = try await requestWithLaunch(method: "room.create", params: params)?["room"] else {
            throw DaemonClient.DaemonError.request("room.create returned no room")
        }
        return try JSONDecoder().decode(Room.self, from: JSONEncoder().encode(raw))
    }

    func sendRoom(_ room: String, text: String, idempotencyKey: String = "mac-room-\(UUID().uuidString)") async throws {
        _ = try await requestWithLaunch(method: "room.send", params: [
            "room": AnyEncodable(room), "text": AnyEncodable(text),
            "idempotency_key": AnyEncodable(idempotencyKey),
        ])
    }

    func leaveRoom(_ room: String) async throws {
        _ = try await requestWithLaunch(method: "room.leave", params: ["room": AnyEncodable(room)])
    }

    func sendText(to peer: String, _ text: String, conversation: String? = nil) async throws {
        var params: [String: AnyEncodable] = [
            "to": AnyEncodable(peer),
            "text": AnyEncodable(text),
            "idempotency_key": AnyEncodable("mac-\(UUID().uuidString)"),
        ]
        if let conversation { params["conversation"] = AnyEncodable(conversation) }
        _ = try await requestWithLaunch(method: "message.send", params: params)
    }

    /// Replays retained events for initial ChatStore hydration.
    func events(after cursor: String?) async throws -> [Event] {
        var params: [String: AnyEncodable] = [:]
        if let cursor { params["after"] = AnyEncodable(cursor) }
        guard let list = try await requestWithLaunch(method: "events", params: params)?["events"]?.asArray else { return [] }
        return try JSONDecoder().decode([Event].self, from: JSONEncoder().encode(list))
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
    /// Add Channel flow).
    func addChannel(name: String, ticketJSON: String, identity: String) async throws {
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
        for capability in ["message.send", "message.receive", "live.audio.subscribe"] {
            _ = try await requestWithLaunch(method: "access.grant", params: [
                "identity": AnyEncodable(identity),
                "subject": AnyEncodable(endpointId),
                "capability": AnyEncodable(capability),
            ])
        }
    }
}