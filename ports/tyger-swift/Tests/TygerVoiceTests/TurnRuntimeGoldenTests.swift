import AVFoundation
import XCTest
@testable import TygerVoice

/// Flag-off is the contract: the windowed cut tier must behave exactly as it did
/// before the 320 ms prefix existed. This pins the runtime's per-frame 8-vectors —
/// the only input the rules and thresholds see — on a fixed fixture, so a change
/// that leaks into the default path (a shared buffer, an extra encode, a reset that
/// moved) fails here even though `TurnRuntimeTests` only checks the oracle envelope.
///
/// Recorded from the pre-prefix runtime. Re-record only with a deliberate tier
/// change: `IDFON_TURN_RECORD=1 swift test --filter TurnRuntimeGoldenTests`.
final class TurnRuntimeGoldenTests: XCTestCase {
    private static let hops = 30   // 9.6 s: crosses the 8 s window into the sliding regime

    private var repoRoot: URL {
        // .../ports/tyger-swift/Tests/TygerVoiceTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var bench: URL {
        ProcessInfo.processInfo.environment["IDFON_BENCH"].map { URL(fileURLWithPath: $0) }
            ?? repoRoot.appendingPathComponent("bench-results")
    }

    private var fixtureDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("runtime")
    }

    func testFlagOffOutputsAreUnchanged() throws {
        // The shipped L4 cut (docs § "Tier state"); the L15 pair is the fallback tier.
        func firstExisting(_ urls: [URL]) -> URL {
            urls.first { FileManager.default.fileExists(atPath: $0.path) } ?? urls[0]
        }
        let enc = firstExisting([
            bench.appendingPathComponent("coreml-l4/TygerEncoderL4.mlpackage"),
            bench.appendingPathComponent("coreml/TygerEncoder.mlpackage"),
        ])
        let dyn = firstExisting([
            bench.appendingPathComponent("coreml-l4/TygerEncoderL4Dyn.mlpackage"),
            bench.appendingPathComponent("coreml/TygerEncoderDyn.mlpackage"),
        ])
        let student = bench.appendingPathComponent("coreml/StudentStep.mlpackage")
        let teacher = bench.appendingPathComponent("coreml/TygerStep.mlpackage")
        let step = FileManager.default.fileExists(atPath: student.path) ? student : teacher
        let a = fixtureDir.appendingPathComponent("ch0.wav")
        let b = fixtureDir.appendingPathComponent("ch1.wav")
        for url in [enc, dyn, step, a, b] where !FileManager.default.fileExists(atPath: url.path) {
            throw XCTSkip("cut tier or runtime fixture missing: \(url.lastPathComponent)")
        }

        let user = try readWav(a), agent = try readWav(b)
        let rt = try TurnRuntime(encoderURL: enc, encoderDynURL: dyn, stepURL: step)
        var got: [[Float]] = []
        for h in 0..<Self.hops {
            let s = h * TurnRuntime.hopSamples
            guard s + TurnRuntime.hopSamples <= min(user.count, agent.count) else { break }
            got.append(contentsOf: rt.feed(userHop: Array(user[s..<s + TurnRuntime.hopSamples]),
                                           agentHop: Array(agent[s..<s + TurnRuntime.hopSamples]),
                                           prevState: { _ in 0 }))
        }

        let goldenURL = fixtureDir.appendingPathComponent("windowed-golden.json")
        if ProcessInfo.processInfo.environment["IDFON_TURN_RECORD"] == "1" {
            let json = try JSONSerialization.data(withJSONObject: ["frames": got], options: [.sortedKeys])
            try json.write(to: goldenURL)
            print("recorded \(got.count) frames to \(goldenURL.path)")
            return
        }

        let root = try JSONSerialization.jsonObject(with: try Data(contentsOf: goldenURL)) as? [String: Any]
        let expected = try XCTUnwrap(root?["frames"] as? [[Double]], "malformed golden")
        XCTAssertEqual(got.count, expected.count, "frame count")
        // Same machine, same artifacts, same code path: exact. A wiring change is O(1),
        // so even if a future OS makes ANE inference non-deterministic, this must not
        // become a loose tolerance.
        for (i, (g, e)) in zip(got, expected).enumerated() {
            XCTAssertEqual(g.count, e.count)
            for k in 0..<min(g.count, e.count) {
                XCTAssertEqual(g[k], Float(e[k]), "frame \(i) head \(k)")
            }
        }
    }

    private func readWav(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let n = AVAudioFrameCount(f.length)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try f.read(into: buf)
        let ch = buf.floatChannelData![0]
        return (0..<Int(n)).map { ch[$0] }
    }
}
