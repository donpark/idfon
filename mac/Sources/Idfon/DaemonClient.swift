import Foundation
import CIdfon

/// JSON IPC protocol types (idfon-protocol). Contract: docs/protocol.md.
enum Protocol {
    static let version = 1
}

struct ProtocolRequest: Encodable {
    let version: Int
    let id: String
    let method: String
    let params: [String: AnyEncodable]

    init(method: String, params: [String: AnyEncodable] = [:]) {
        self.version = Protocol.version
        self.id = "mac-\(UUID().uuidString)"
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

/// Type-erased Encodable/Decodable so params and results can hold arbitrary
/// JSON produced or consumed dynamically.
struct AnyEncodable: Encodable, Decodable {
    let value: Any

    subscript(key: String) -> AnyEncodable? {
        (value as? [String: AnyEncodable])?[key]
    }

    subscript(index: Int) -> AnyEncodable? {
        (value as? [AnyEncodable])?[index]
    }

    var asArray: [AnyEncodable]? { value as? [AnyEncodable] }

    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyEncodable].self) {
            value = array
        } else if let object = try? container.decode([String: AnyEncodable].self) {
            value = object
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Int64: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [AnyEncodable]: try container.encode(v)
        case let v as [String: AnyEncodable]: try container.encode(v)
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "unsupported JSON type"))
        }
    }
}

/// One-shot JSON IPC client over the C ABI. Thread-safe: each request opens
/// its own daemon connection (same model the CLI uses). On a failed connect
/// the daemon is spawned once and the request retried (the GUI shell does
/// the same in native/src/iroh_ffi.zig launchDaemon).
actor DaemonClient {
    private let socketPath: String

    init(socketPath: String = DaemonRuntime.socketPath) {
        self.socketPath = socketPath
    }

    enum DaemonError: LocalizedError {
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
    /// requests can block for seconds (connect timeout) to 30s+ (wait/blob
    /// fetch), and a sync blocking call inside an actor pins a
    /// cooperative-pool thread, starving other async work on slow networks.
    nonisolated func request(method: String, params: [String: AnyEncodable] = [:]) async throws -> AnyEncodable? {
        try await Task.detached(priority: .userInitiated) {
            try self.rawRequest(method: method, params: params, connectTimeoutMs: 5_000)
        }.value
    }

    private nonisolated func rawRequest(method: String, params: [String: AnyEncodable], connectTimeoutMs: UInt32) throws -> AnyEncodable? {
        let payload = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: JSONEncoder().encode(ProtocolRequest(method: method, params: params)))
        )
        var out: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        var ok: UInt8 = 0
        let rc = payload.withUnsafeBytes { buffer in
            idfon_client_request(socketPath, buffer.bindMemory(to: UInt8.self).baseAddress, payload.count, &out, &outLen, &ok, connectTimeoutMs)
        }
        guard rc == IDFON_OK, let out, outLen > 0 else {
            if let out { idfon_client_result_free(out, outLen) }
            throw rc == IDFON_ECONNECT ? DaemonError.connect : DaemonError.request("idfon_client_request failed: \(rc)")
        }
        defer { idfon_client_result_free(out, outLen) }
        let data = Data(bytes: out, count: Int(outLen))
        let response = try JSONDecoder().decode(ProtocolResponse.self, from: data)
        guard response.ok else {
            throw DaemonError.request(response.error?.message ?? "request failed")
        }
        return response.result
    }

    /// Request with one daemon-launch retry on connect failure.
    nonisolated func requestWithLaunch(method: String, params: [String: AnyEncodable] = [:]) async throws -> AnyEncodable? {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try self.rawRequest(method: method, params: params, connectTimeoutMs: 500)
            }.value
        } catch DaemonError.connect {
            DaemonRuntime.launchIfNeeded()
            return try await Task.detached(priority: .userInitiated) {
                try self.rawRequest(method: method, params: params, connectTimeoutMs: 10_000)
            }.value
        }
    }
}