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

    func contactTicket(identity: String? = nil) async throws -> String {
        var params: [String: AnyEncodable] = [:]
        if let identity { params["identity"] = AnyEncodable(identity) }
        guard let raw = try await requestWithLaunch(method: "contact.ticket", params: params) else { return "" }
        return String(data: try JSONEncoder().encode(raw), encoding: .utf8) ?? ""
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

    /// Renames a contact (`peer.update` with the pair's `ref` and a new name).
    func renamePeer(ref: String, name: String) async throws {
        let identity = (try? await identityId()) ?? "default"
        _ = try await requestWithLaunch(method: "peer.update", params: [
            "ref": AnyEncodable(ref),
            "identity": AnyEncodable(identity),
            "name": AnyEncodable(name),
        ])
    }

    /// Removes a contact (`peer.remove`).
    func removePeer(ref: String) async throws {
        let identity = (try? await identityId()) ?? "default"
        _ = try await requestWithLaunch(method: "peer.remove", params: [
            "ref": AnyEncodable(ref),
            "identity": AnyEncodable(identity),
        ])
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

    func sendText(to peer: String, _ text: String, conversation: String? = nil,
                  context: String? = nil) async throws {
        var params: [String: AnyEncodable] = [
            "to": AnyEncodable(peer),
            "text": AnyEncodable(text),
            "idempotency_key": AnyEncodable("mac-\(UUID().uuidString)"),
        ]
        if let conversation { params["conversation"] = AnyEncodable(conversation) }
        // Per-turn caller context (unsigned, untrusted data): the active
        // caller-side state the UI applied to this turn.
        if let context { params["context"] = AnyEncodable(context) }
        // Gated peers (the Eve agent's holder) require their holder-signed
        // ticket; ungated peers ignore it and use local grants.
        if let ticket = CapabilityTickets.ticket(for: peer) {
            params["capability_ticket"] = ticket
        }
        // Call invites must survive transport hiccups (relay reconnects on
        // the peer take tens of seconds); the receiving daemon dedupes by
        // message id, so retries are safe.
        params["retries"] = AnyEncodable(3)
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
        guard let ticket = try JSONSerialization.jsonObject(with: Data(ticketJSON.utf8)) as? [String: Any] else {
            throw DaemonError.request("invalid contact ticket JSON")
        }
        let transport = (ticket["endpoint_addr"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? ticket
        guard let endpointId = (ticket["endpoint_id"] as? String) ?? (transport["id"] as? String), !endpointId.isEmpty else {
            throw DaemonError.request("ticket has no endpoint_id")
        }
        let accountId = (ticket["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? endpointId
        let endpointAddr = (ticket["endpoint_addr"] as? String) ?? ticketJSON
        _ = try await requestWithLaunch(method: "peer.add", params: [
            "id": AnyEncodable(accountId),
            "name": AnyEncodable(name),
            "endpoint_id": AnyEncodable(endpointId),
            "endpoint_addr": AnyEncodable(endpointAddr),
            "identity": AnyEncodable(identity),
        ])
        for capability in ["message.send", "message.receive", "live.audio.subscribe", "resource.read"] {
            _ = try await requestWithLaunch(method: "access.grant", params: [
                "identity": AnyEncodable(identity),
                "subject": AnyEncodable(accountId),
                "capability": AnyEncodable(capability),
            ])
        }
    }

    /// Exposes the app's user-visible `Documents/Shared` directory to granted
    /// peers at `GET /fs/<path>`. Idempotent, and the daemon serves the dir in
    /// place — anything the user drops into it in Finder is shareable; a rename
    /// or delete is reflected immediately. Retries while the daemon wakes up.
    func startSharedProvider() async {
        guard let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let shared = documents.appendingPathComponent("Shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        for attempt in 0..<5 {
            do {
                _ = try await requestWithLaunch(method: "provider.start", params: [
                    "root": AnyEncodable(shared.path),
                ])
                return
            } catch {
                try? await Task.sleep(nanoseconds: 500_000_000 * UInt64(attempt + 1))
            }
        }
    }

    /// Binds this identity's loopback gateway. Returns the base address
    /// (host:port) and the bearer token every request must carry.
    func gatewayStart() async throws -> (addr: String, token: String) {
        guard let result = try await request(method: "gateway.start"),
              let addr = result["addr"]?.stringValue,
              let token = result["token"]?.stringValue else {
            throw DaemonError.request("gateway.start returned no address")
        }
        return (addr, token)
    }

    /// Fetches a peer resource through the loopback gateway. `account` is a
    /// peer ref the daemon resolves (id, alias, endpoint id); `path` starts
    /// with `/`.
    func fetchRemoteResource(account: String, path: String) async throws -> Data {
        let gateway = try await gatewayStart()
        guard let url = URL(string: "http://\(gateway.addr)/\(account)\(path)") else {
            throw DaemonError.request("invalid gateway URL for \(account)")
        }
        var httpRequest = URLRequest(url: url)
        httpRequest.setValue("Bearer \(gateway.token)", forHTTPHeaderField: "Authorization")
        httpRequest.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: httpRequest)
        guard let http = response as? HTTPURLResponse else {
            throw DaemonError.request("gateway returned no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw DaemonError.request("gateway returned HTTP \(http.statusCode)")
        }
        return data
    }
}