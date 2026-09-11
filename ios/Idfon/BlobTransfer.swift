import Foundation

/// Chunked blob store/fetch over the protocol (mirrors the CLI's put/fetch).
extension DaemonClient {
    /// Chunked blob store (media.resource.put; mirrors the CLI's put_data:
    /// single-chunk puts carry finish=false and the ticket comes back in that
    /// response; multi-chunk sends a trailing empty finish=true).
    func putData(_ data: Data, resourceId: String) async throws -> String {
        let chunkSize = 200_000
        var offset = 0
        var ticket = ""
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let response = try await request(method: "media.resource.put", params: [
                "resource_id": AnyEncodable(resourceId),
                "bytes": AnyEncodable(data[offset..<end].map { AnyEncodable(Int($0)) }),
                "append": AnyEncodable(offset > 0),
                "finish": AnyEncodable(false),
            ])
            ticket = response?["blob_ticket"]?.stringValue ?? ticket
            offset = end
        }
        if data.count > chunkSize {
            let response = try await request(method: "media.resource.put", params: [
                "resource_id": AnyEncodable(resourceId),
                "bytes": AnyEncodable([]),
                "append": AnyEncodable(false),
                "finish": AnyEncodable(true),
            ])
            ticket = response?["blob_ticket"]?.stringValue ?? ticket
        }
        return ticket
    }

    /// Chunked blob fetch by ticket. Returns the raw bytes.
    func fetchBlob(_ ticket: String) async throws -> Data {
        let trackingId = "ios-\(UUID().uuidString)"
        var result = Data()
        var offset = 0
        let chunkSize = 200_000
        while true {
            let response = try await request(method: "media.resource.fetch", params: [
                "resource_id": AnyEncodable(trackingId),
                "blob_ticket": AnyEncodable(ticket),
                "offset": AnyEncodable(offset),
                "length": AnyEncodable(chunkSize),
            ])
            guard let bytes = response?["bytes"]?.asArray else { break }
            result.append(contentsOf: bytes.compactMap { value -> UInt8? in
                if let u = value.value as? UInt8 { return u }
                if let i = value.value as? Int, (0...255).contains(i) { return UInt8(i) }
                return nil
            })
            offset += bytes.count
            if bytes.count < chunkSize { break }
        }
        return result
    }
}
