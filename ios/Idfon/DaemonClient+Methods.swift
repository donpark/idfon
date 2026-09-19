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

    func identities() async throws -> [IdentityInfo] {
        guard let list = try await request(method: "identities")?["identities"]?.asArray else { return [] }
        return try JSONDecoder().decode([IdentityInfo].self, from: JSONEncoder().encode(list))
    }

    func contactTicket(identity: String? = nil) async throws -> String {
        var params: [String: AnyEncodable] = [:]
        if let identity { params["identity"] = AnyEncodable(identity) }
        guard let raw = try await request(method: "contact.ticket", params: params) else { return "" }
        return String(data: try JSONEncoder().encode(raw), encoding: .utf8) ?? ""
    }

    func useIdentity(_ name: String) async throws {
        _ = try await request(method: "identity.use", params: ["name": AnyEncodable(name)])
    }

    func createIdentity(_ name: String) async throws {
        _ = try await request(method: "identity.create", params: ["name": AnyEncodable(name)])
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

    func rooms() async throws -> [Room] {
        guard let list = try await request(method: "room.list")?["rooms"]?.asArray else { return [] }
        return try JSONDecoder().decode([Room].self, from: JSONEncoder().encode(list))
    }

    func joinRoom(_ room: String, name: String? = nil, members: [String] = []) async throws -> Room {
        var params: [String: AnyEncodable] = ["room": AnyEncodable(room)]
        if let name { params["name"] = AnyEncodable(name) }
        if !members.isEmpty { params["members"] = AnyEncodable(members.map(AnyEncodable.init)) }
        guard let raw = try await request(method: "room.join", params: params)?["room"] else {
            throw DaemonClient.DaemonError.request("room.join returned no room")
        }
        return try JSONDecoder().decode(Room.self, from: JSONEncoder().encode(raw))
    }

    func createRoom(id: String? = nil, name: String? = nil, members: [String] = []) async throws -> Room {
        var params: [String: AnyEncodable] = [:]
        if let id { params["id"] = AnyEncodable(id) }
        if let name { params["name"] = AnyEncodable(name) }
        if !members.isEmpty { params["members"] = AnyEncodable(members.map(AnyEncodable.init)) }
        guard let raw = try await request(method: "room.create", params: params)?["room"] else {
            throw DaemonClient.DaemonError.request("room.create returned no room")
        }
        return try JSONDecoder().decode(Room.self, from: JSONEncoder().encode(raw))
    }

    func sendRoom(_ room: String, text: String, idempotencyKey: String = "ios-room-\(UUID().uuidString)") async throws {
        _ = try await request(method: "room.send", params: [
            "room": AnyEncodable(room), "text": AnyEncodable(text),
            "idempotency_key": AnyEncodable(idempotencyKey),
        ])
    }

    func leaveRoom(_ room: String) async throws {
        _ = try await request(method: "room.leave", params: ["room": AnyEncodable(room)])
    }

    /// Attaches the peer's provisioned capability ticket when there is one
    /// (`CapabilityTickets`); gated peers such as the Eve agent's holder
    /// require it, ungated idfon peers ignore it and use local grants.
    func sendText(to peer: String, _ text: String, conversation: String? = nil) async throws {
        var params: [String: AnyEncodable] = [
            "to": AnyEncodable(peer),
            "text": AnyEncodable(text),
            "idempotency_key": AnyEncodable("ios-\(UUID().uuidString)"),
        ]
        if let conversation { params["conversation"] = AnyEncodable(conversation) }
        if let ticket = CapabilityTickets.ticket(for: peer) {
            params["capability_ticket"] = ticket
        }
        _ = try await request(method: "message.send", params: params)
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
