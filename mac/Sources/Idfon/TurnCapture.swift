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
    }

    /// Write the stereo wav; nil when nothing was captured.
    @discardableResult
    func finish() -> URL? {
        guard !user.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "turn-\(ISO8601DateFormatter().string(from: started)).wav"
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
        return url
    }
}
