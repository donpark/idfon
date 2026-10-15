import Foundation

/// JSON IPC protocol types (idfon-protocol). Contract: docs/protocol.md.
enum Protocol {
    static let version = 2
}

struct ProtocolRequest: Encodable {
    let version: Int
    let id: String
    let method: String
    let params: [String: AnyEncodable]

    init(method: String, params: [String: AnyEncodable] = [:]) {
        self.version = Protocol.version
        self.id = "ios-\(UUID().uuidString)"
        self.method = method
        self.params = params
    }
}

struct ProtocolResponse: Decodable {
    struct Error: Decodable {
        let code: String
        let message: String
        let retryable: Bool
    }

    let id: String
    let ok: Bool
    let operation: String?
    let result: AnyEncodable?
    let error: Error?
}

/// JSON client for the feature set the app embeds: the daemon core runs
/// in-process and this calls it directly (`idfon_request`) — no socket, no
/// separate lifecycle. Thread-safe: each request is a self-contained call.
actor IdfonClient {
    enum RequestError: LocalizedError {
        case connect
        case request(String)

        var errorDescription: String? {
            switch self {
            case .connect: return "daemon not reachable"
            case .request(let message): return message
            }
        }
    }

    /// The blocking C call hops off the actor's executor onto a detached task:
    /// requests can block for seconds (connect/startup retry) to 30s+ (wait/blob
    /// fetch), and a sync blocking call inside an actor pins a
    /// cooperative-pool thread, starving other async work on slow networks.
    nonisolated func request(method: String, params: [String: AnyEncodable] = [:]) async throws -> AnyEncodable? {
        try await Task.detached(priority: .userInitiated) {
            try self.blockingRequest(method: method, params: params)
        }.value
    }

    private nonisolated func blockingRequest(method: String, params: [String: AnyEncodable]) throws -> AnyEncodable? {
        let payload = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: JSONEncoder().encode(ProtocolRequest(method: method, params: params)))
        )
        var out: UnsafeMutablePointer<UInt8>?
        var outLen: UInt = 0
        var ok: UInt8 = 0
        let rc = payload.withUnsafeBytes { buffer in
            idfon_request(buffer.bindMemory(to: UInt8.self).baseAddress, UInt(payload.count), &out, &outLen, &ok)
        }
        guard rc == IDFON_OK, let out, outLen > 0 else {
            if let out { idfon_client_result_free(out, outLen) }
            throw rc == IDFON_ECONNECT ? RequestError.connect : RequestError.request("idfon_request failed: \(rc)")
        }
        defer { idfon_client_result_free(out, outLen) }
        let data = Data(bytes: out, count: Int(outLen))
        let response = try JSONDecoder().decode(ProtocolResponse.self, from: data)
        guard response.ok else {
            throw RequestError.request(response.error?.message ?? "request failed")
        }
        return response.result
    }
}
