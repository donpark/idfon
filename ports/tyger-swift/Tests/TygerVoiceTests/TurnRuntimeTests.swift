import AVFoundation
import XCTest
@testable import TygerVoice

/// End-to-end numeric parity for the Swift feed loop: fixtures are the torch
/// oracle's per-frame 8-vectors over a real conversation slice (prev_state held
/// at 0 — the rules threading is covered by the Rust fixture suite).
final class TurnRuntimeTests: XCTestCase {
    func testRuntimeMatchesTheOracle() throws {
        let here = URL(fileURLWithPath: #filePath)
        let pkg = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let models = pkg.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bench-results/coreml")
        let enc = models.appendingPathComponent("TygerEncoder.mlpackage")
        let encDyn = models.appendingPathComponent("TygerEncoderDyn.mlpackage")
        let step = models.appendingPathComponent("TygerStep.mlpackage")
        guard FileManager.default.fileExists(atPath: enc.path),
              FileManager.default.fileExists(atPath: encDyn.path),
              FileManager.default.fileExists(atPath: step.path) else {
            throw XCTSkip("Core ML models not exported (ports/tyger-coreml/export.py)")
        }
        let fxDir = here.deletingLastPathComponent().appendingPathComponent("runtime")
        let exp = try JSONDecoder().decode(
            Expectations.self, from: try Data(contentsOf: fxDir.appendingPathComponent("expectations.json")))
        let user = try readWav(fxDir.appendingPathComponent("ch0.wav"))
        let agent = try readWav(fxDir.appendingPathComponent("ch1.wav"))

        let rt = try TurnRuntime(encoderURL: enc, encoderDynURL: encDyn, stepURL: step)
        var got: [[Float]] = []
        var h = 0
        while (h + 1) * exp.hopSamples <= min(user.count, agent.count) {
            let s = h * exp.hopSamples
            got.append(contentsOf: rt.feed(
                userHop: Array(user[s..<s + exp.hopSamples]),
                agentHop: Array(agent[s..<s + exp.hopSamples]),
                prevState: { _ in 0 }))
            h += 1
        }
        XCTAssertEqual(got.count, exp.frames.count, "frame count")
        // The contract is the accepted fp16 tier's record (parity6, docs/voice-tyger-
        // ondevice.md): drift vs the fp32 oracle stays inside the recorded envelope,
        // and the MEAN stays small — a wiring bug is O(1), the tier drift is not.
        let envelope: [Double] = [0.7, 0.7, 0.7, 0.7, 0.06, 0.04, 0.05, 0.05]
        var worst = [Double](repeating: 0, count: 8)
        var sum = [Double](repeating: 0, count: 8)
        for (g, w) in zip(got, exp.frames) {
            for k in 0..<8 {
                let d = abs(Double(g[k]) - w[k])
                worst[k] = max(worst[k], d)
                sum[k] += d
            }
        }
        for k in 0..<8 {
            let mean = sum[k] / Double(exp.frames.count)
            XCTAssertLessThanOrEqual(worst[k], envelope[k], "head \(k) max (tier envelope)")
            // wiring bugs are O(1); the tier's state-logit drift is not. Probability
            // heads (4-7) are what decisions threshold — kept tight.
            let meanBudget: Double = k < 4 ? 0.05 : 0.02
            XCTAssertLessThanOrEqual(mean, meanBudget, "head \(k) mean (wiring check)")
        }
    }

    struct Expectations: Decodable {
        let hopSamples: Int
        let frames: [[Double]]
        enum CodingKeys: String, CodingKey { case hopSamples = "hop_samples", frames }
    }

    private func readWav(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let n = AVAudioFrameCount(f.length)
        let fmt = f.processingFormat
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        try f.read(into: buf)
        let ch = buf.floatChannelData![0]
        return (0..<Int(n)).map { ch[$0] }
    }
}
