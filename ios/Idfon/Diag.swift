import Foundation

/// Diagnostics over iroh (`IDFON-DIAG/1`, `crates/idfon-protocol/src/diag.rs`).
/// The app ships events to a monitor peer — the 2026-10-23 wake-saga lesson:
/// iroh was the only channel that never failed, and remote log access was the
/// binding constraint. Events batch in memory and flush as one bounded
/// report. Fail-open by construction: a send failure costs the batch, never a
/// call or a wake.
enum Diag {
    /// The monitor peer id: `-diagpeer <peerId>` at launch, else the saved one.
    static var monitorPeer: String? = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-diagpeer"), args.count > i + 1 {
            let peer = args[i + 1]
            UserDefaults.standard.set(peer, forKey: "idfon.diag.peer")
            return peer
        }
        return UserDefaults.standard.string(forKey: "idfon.diag.peer")
    }()

    /// Set at launch: the app's message sender (the per-app client type).
    static var send: ((String, String) async throws -> Void)?
    /// The sending device: the identity id when known (set at launch).
    static var device = "unknown"
    /// The build stamp the field actually runs.
    static var build = "unknown"

    private static let lock = NSLock()
    private static var events: [[String: Any]] = []
    private static let maxBatch = 64

    /// Record one event. Cheap and thread-safe; nothing is sent yet.
    static func log(_ kind: String, _ detail: [String: Any] = [:]) {
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        var event: [String: Any] = ["ts_ms": ts, "kind": kind]
        if !detail.isEmpty { event["detail"] = detail }
        lock.lock()
        events.append(event)
        let over = events.count >= maxBatch
        lock.unlock()
        if over { flush() }
    }

    /// Ship the per-call quality record (media-adaptation §C1) folded at
    /// `media_live_stop()`. Read-and-clear on the Rust side, so call this
    /// exactly once per call — right after the stop. Parse-and-log: a record
    /// that will not parse still ships as a raw string, never loses a call.
    static func logCallRecord() {
        guard let ptr = media_health_last_report() else { return }
        let json = String(cString: ptr)
        rust_free_string(ptr)
        guard !json.isEmpty else { return }
        let detail: [String: Any]
        if let data = json.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            detail = parsed
        } else {
            detail = ["raw": json]
        }
        log("call", detail)
        flush()
    }

    /// Send the buffered events to the monitor peer as one report.
    static func flush() {
        guard let peer = monitorPeer, let send else { return }
        lock.lock()
        let batch = events
        events = []
        lock.unlock()
        guard !batch.isEmpty else { return }
        let report: [String: Any] = ["device": device, "build": build, "events": batch]
        guard let data = try? JSONSerialization.data(withJSONObject: report),
              let json = String(data: data, encoding: .utf8) else { return }
        let text = "IDFON-DIAG/1\n" + json
        Task { try? await send(peer, text) }
    }
}
