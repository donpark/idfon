import Foundation

/// Two-stream turn capture: the model's native input (caller mic + agent
/// playback, aligned) recorded during live calls — the idfon advantage over
/// mixed recordings (`docs/voice-tyger-option.md`, the voice-agent-trainer).
/// Stereo 16 kHz s16 wav: ch0 = mic, ch1 = agent. Capped so a forgotten call
/// cannot fill the disk; `finish()` writes the file and returns its URL.
final class TurnCapture {
    private var user: [Float] = []
    private var agent: [Float] = []
    private let capSamples: Int
    private let dir: URL
    private let started = Date()
    private var overflowed = false
    /// Second-ear evidence, written beside the wav: if the agent channel stays
    /// zero the model ran blind (the 2026-11-01 live call), and no threshold
    /// tuning can be read from it.
    private var agentHops = 0
    private var agentNonSilent = 0
    private var agentPeak: Float = 0

    /// `capSeconds` bounds the recording (default 10 min ≈ 38 MB).
    init(dir: URL, capSeconds: Double = 600) {
        self.dir = dir
        self.capSamples = Int(capSeconds * 16000)
    }

    /// One paired hop (16 kHz mono each).
    func append(userHop: [Float], agentHop: [Float]) {
        guard !overflowed, user.count + userHop.count <= capSamples else {
            overflowed = true
            return
        }
        user.append(contentsOf: userHop)
        agent.append(contentsOf: agentHop)
        agentHops += 1
        let peak = agentHop.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 1e-4 { agentNonSilent += 1 }
        agentPeak = max(agentPeak, peak)
    }

    /// Write the stereo wav; nil when nothing was captured.
    @discardableResult
    func finish() -> URL? {
        guard !user.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // No colons: the simulator/macOS path layer mangles them and
        // `devicectl copy from` cannot address the file at all.
        let stamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "-")
        let name = "turn-\(stamp).wav"
        let url = dir.appendingPathComponent(name)
        let frames = user.count
        var data = Data(capacity: 44 + frames * 4)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + frames * 4)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(2); u32(16000)
        u32(16000 * 2 * 2); u16(4); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(frames * 4))
        for i in 0..<frames {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, user[i])) * 32767)))
            u16(UInt16(bitPattern: Int16(max(-1, min(1, agent[i])) * 32767)))
        }
        try? data.write(to: url)
        let sidecar: [String: Any] = ["frames": frames, "agentHops": agentHops,
                                      "agentNonSilent": agentNonSilent, "agentPeak": agentPeak]
        if let json = try? JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys]) {
            try? json.write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }
        Automation.mark("turn-capture: agent hops \(agentNonSilent)/\(agentHops) non-silent peak \(String(format: "%.4f", agentPeak))")
        return url
    }
}
