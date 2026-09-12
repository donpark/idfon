import Foundation

/// Chunked blob store/fetch over the protocol (mirrors the CLI's put/fetch).
extension DaemonClient {
    /// Chunked blob store (media.resource.put; mirrors the CLI's put_data:
    /// single-chunk puts carry finish=false and the ticket comes back in that
    /// response; multi-chunk sends a trailing empty finish=true).
    /// `onProgress` receives (bytesSent, totalBytes) after each chunk; it is
    /// called on whatever executor this runs on. Cancelling the enclosing task
    /// aborts at the next chunk boundary.
    func putData(_ data: Data, resourceId: String,
                 onProgress: ((Int, Int) -> Void)? = nil) async throws -> String {
        try await put(total: data.count, resourceId: resourceId, onProgress: onProgress) { start, end in
            data.subdata(in: start..<end)
        }
    }

    /// Same put, reading one chunk at a time from disk so large files never sit
    /// in memory.
    func putFile(at url: URL, resourceId: String,
                 onProgress: ((Int, Int) -> Void)? = nil) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return try await put(total: total, resourceId: resourceId, onProgress: onProgress) { start, end in
            try handle.seek(toOffset: UInt64(start))
            return try handle.read(upToCount: end - start) ?? Data()
        }
    }

    private func put(total: Int, resourceId: String, onProgress: ((Int, Int) -> Void)?,
                     read: (Int, Int) throws -> Data) async throws -> String {
        let chunkSize = 200_000
        var offset = 0
        var ticket = ""
        while offset < total {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, total)
            let chunk = try read(offset, end)
            let response = try await request(method: "media.resource.put", params: [
                "resource_id": AnyEncodable(resourceId),
                "bytes": AnyEncodable(chunk.map { AnyEncodable(Int($0)) }),
                "append": AnyEncodable(offset > 0),
                "finish": AnyEncodable(false),
            ])
            ticket = response?["blob_ticket"]?.stringValue ?? ticket
            offset = end
            onProgress?(offset, total)
        }
        if total > chunkSize {
            try Task.checkCancellation()
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
    /// ponytail: whole blob in memory; stream to disk if multi-hundred-MB
    /// receives become real.
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
