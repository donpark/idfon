import Foundation

/// The live-call decision record (#102): what the turn rules decided during a
/// real call, per 80 ms frame. A ``TurnEngine`` writes it only when
/// `IDFON_TURN_LOG` names a file; with the variable unset no file is created
/// and no frame touches this type (`TurnEngine`'s default is `nil`).
///
/// Layout: one JSON object per line, buffered and appended on a utility queue.
/// A session starts with a header (`rec: "session"` — id, app/build, tier meta,
/// sample rate, hop, and the monotonic `origin_ns` every frame's `t_ms` is
/// measured from), then one line per frame (`rec: "frame"`). A log file may
/// hold several sessions (a call ends, another appends); the header delimits
/// them. `endHop()` batches the frames of one hop, `close()` drains the rest.
///
/// The frames deliberately carry no audio and no encoder features: the paired
/// capture (`TurnCapture`'s stereo wav) is the audio, and
/// `ports/tyger-student/featurize.py --wavs` turns it into features. What only
/// the live call knows — the 8-vectors, the rules input, the events — is here.
public final class TurnTrace {
    public static let envKey = "IDFON_TURN_LOG"

    /// Two callers, one lock. The audio path never touches this type:
    /// `TurnEngine.feed` runs on the shadow's own serial queue.
    private let queue = DispatchQueue(label: "idfon.turn-trace", qos: .utility)
    private let lock = NSLock()
    private let handle: FileHandle
    private let session = UUID().uuidString
    private let originNs = DispatchTime.now().uptimeNanoseconds
    private var pending = ""
    private var closed = false
    private static let flushBytes = 32 * 1024

    /// The default record path when `IDFON_TURN_LOG` is unset. A bare name (no `/`)
    /// lands in the app's Documents directory, which is what `devicectl copy from`
    /// needs on a physical iPhone.
    public static let defaultFileName = "turn-log.jsonl"

    /// **On by default since 2026-11-05**: the split tier is judged in real use, so a
    /// normal launch records decisions to `Documents/turn-log.jsonl`. The file holds
    /// per-frame decisions only — no audio; `TurnCapture` stays a separate, deliberate
    /// act. `IDFON_TURN_LOG=0` (or `off`) disables it, any other value is the path.
    public static func fromEnvironment(
        sampleRate: Int = TurnRuntime.sampleRate,
        hopSamples: Int = TurnRuntime.hopSamples,
        meta: [String: String] = [:]
    ) -> TurnTrace? {
        let raw = ProcessInfo.processInfo.environment[envKey]
        let name: String
        if let raw, !raw.isEmpty {
            guard !["0", "false", "no", "off"].contains(raw.lowercased()) else { return nil }
            name = raw
        } else {
            name = defaultFileName
        }
        return TurnTrace(path: name, sampleRate: sampleRate, hopSamples: hopSamples, meta: meta)
    }

    private init?(path raw: String, sampleRate: Int, hopSamples: Int, meta: [String: String]) {
        let url = raw.contains("/")
            ? URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(raw)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            NSLog("turn-trace: cannot open \(url.path)")
            return nil
        }
        try? handle.seekToEnd()
        self.handle = handle
        let info = Bundle.main.infoDictionary
        var header: [String: Any] = [
            "rec": "session",
            "session": session,
            "started_at": ISO8601DateFormatter().string(from: Date()),
            "origin_ns": Double(originNs), // JSON numbers here are Double-safe at µs resolution
            "rate": sampleRate,
            "hop": hopSamples,
            "app": Bundle.main.bundleIdentifier ?? "-",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "build": "\(info?["CFBundleShortVersionString"] as? String ?? "-") (\(info?["CFBundleVersion"] as? String ?? "-"))",
        ]
        for (k, v) in meta { header[k] = v }
        enqueue(header)
        NSLog("turn-trace: logging to \(url.path)")
    }

    /// One frame, right after its step and its rules call. `prevState` is the
    /// state the step consumed, `events` the non-FRAME events the rules emitted
    /// on this frame.
    public func frame(
        index: Int, out: [Float], actDb: Double, prevState: Int, left: Int,
        mode: String, events: [(kind: String, frame: Int)]
    ) {
        var rec: [String: Any] = [
            "rec": "frame",
            "i": index,
            "t_ms": Double(DispatchTime.now().uptimeNanoseconds &- originNs) / 1_000_000,
            "out": out,
            "act_db": actDb,
            "prev": prevState,
            "left": left,
            "mode": mode,
        ]
        if !events.isEmpty {
            rec["events"] = events.map { ["kind": $0.kind, "frame": $0.frame] }
        }
        enqueue(rec)
    }

    /// End of a hop: hand this hop's frames to the write queue.
    public func endHop() {
        lock.lock()
        let batch = pending
        pending = ""
        lock.unlock()
        if !batch.isEmpty { queue.async { self.append(batch) } }
    }

    /// The call ended: write what is buffered and close. Safe to call twice.
    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let batch = pending
        pending = ""
        lock.unlock()
        queue.sync {
            self.append(batch)
            try? self.handle.close()
        }
    }

    private func enqueue(_ rec: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        pending += text + "\n"
        let full = pending.utf8.count >= Self.flushBytes
        let batch = full ? pending : ""
        if full { pending = "" }
        lock.unlock()
        if !batch.isEmpty { queue.async { self.append(batch) } }
    }

    private func append(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}
