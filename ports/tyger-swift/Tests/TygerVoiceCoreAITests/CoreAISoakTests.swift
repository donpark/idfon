import AVFoundation
import XCTest
@testable import TygerVoice
@testable import TygerVoiceCoreAI

/// The Core AI tier's acceptance on this Mac: oracle parity plus THE soak test.
///
/// The soak is the product flag: the Python binding leaks ~1 IOSurface per
/// inference call and dies at ~8-9k calls (a 30-min voice call is ~28k). If
/// this test crashes with a `CoreAIRuntime/NDArray+SharedStorage` fatal error,
/// the Swift path shares the leak and Core AI cannot drive long calls until
/// Apple fixes it. If it passes, the leak is Python-binding-only.
@available(macOS 27.0, *)
final class CoreAISoakTests: XCTestCase {
    private func modelOrSkip() throws -> CoreAITurnModel {
        do {
            return try CoreAITurnModel()
        } catch let e as CoreAITurnModel.LoadError {
            throw XCTSkip("Core AI artifacts missing (ports/tyger-coreai/export_turn.py): \(e)")
        }
    }

    /// 30k step calls ≈ a 30-minute call's worth — past the Python cliff at ~9k.
    func testSoak30kStepCalls() throws {
        let model = try modelOrSkip()
        let hu = [Float](repeating: 0, count: 1024)
        let ha = [Float](repeating: 0, count: 1024)
        var last: [Float] = []
        for i in 0..<30_000 {
            last = model.step(hu: hu, ha: ha, actDb: -30, prevState: 0)
            if i % 5000 == 0 {
                XCTAssertGreaterThanOrEqual(last.count, 8, "step returned \(last.count) values")
            }
        }
        XCTAssertEqual(last.count, 8, "survived 30k calls")
    }

    func testRuntimeMatchesTheOracle() throws {
        let model = try modelOrSkip()
        let here = URL(fileURLWithPath: #filePath)
        let pkg = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fxDir = pkg.appendingPathComponent("Tests/TygerVoiceTests/runtime")
        let exp = try JSONDecoder().decode(
            Expectations.self, from: try Data(contentsOf: fxDir.appendingPathComponent("expectations.json")))
        let user = try readWav(fxDir.appendingPathComponent("ch0.wav"))
        let agent = try readWav(fxDir.appendingPathComponent("ch1.wav"))

        let rt = TurnRuntime(model: model)
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
        // Exact (fp32) tier contract: tight (the chain gated at ~1e-4 on real
        // audio). The shipping fp16 rung is judged by the accepted fp16 tier's
        // record — parity6's envelope (state ≤ 0.7 / prob heads ≤ 0.06 maxima,
        // the TurnRuntimeTests contract), its decisions by the ±2-frame guard
        // (917/919). Measured here on the fp16 pair: state ≤ 0.038,
        // probs ≤ 0.010 — a wiring bug is O(1) and still trips either.
        let envelope: [Double] = model.usesFloat16
            ? [0.7, 0.7, 0.7, 0.7, 0.06, 0.06, 0.06, 0.06]
            : [2e-3, 2e-3, 2e-3, 2e-3, 1e-3, 1e-3, 1e-3, 1e-3]
        var worst = [Double](repeating: 0, count: 8)
        for (g, w) in zip(got, exp.frames) {
            for k in 0..<8 {
                worst[k] = max(worst[k], abs(Double(g[k]) - w[k]))
            }
        }
        for k in 0..<8 {
            XCTAssertLessThanOrEqual(worst[k], envelope[k], "head \(k) max")
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
