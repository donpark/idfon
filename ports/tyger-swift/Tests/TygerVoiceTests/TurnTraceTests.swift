import XCTest
@testable import TygerVoice

/// The live-call decision log (#102): with `IDFON_TURN_LOG` unset the engine
/// must behave exactly as before (same events, same rules/model call order, no
/// file), and with it set the same run must produce the record the
/// `ports/tyger-student` converter reads. The engine is driven by the same
/// mocks as `TurnEngineTests` — a synthetic dual-stream hop feed.
final class TurnTraceTests: XCTestCase {
    struct Observed: Equatable {
        var events: [String] = []        // "kind@frame"
        var rulesCalls: [String] = []
        var modelPrev: [Int] = []
        var modelActs: [Double] = []
        var frame: Int = 0
    }

    /// Three hops, events on the last two; the mode flips to speaking for hop 3.
    private func driveFixture() -> Observed {
        let model = TurnEngineTests.MockModel()
        let rules = TurnEngineTests.MockRules()
        rules.advanceStatePerFrame = true
        rules.eventsAt = [
            1: [["kind": "FRAME"], ["kind": "BACKCHANNEL"]],
            3: [["kind": "ENDPOINT"]],
        ]
        let engine = TurnEngine(model: model, rules: rules,
                                trace: TurnTrace.fromEnvironment(meta: ["tier": "test"]))
        var seen: [String] = []
        for hop in 0..<3 {
            let events = engine.feed(userHop: [Float](repeating: 0.5, count: 5120),
                                     agentHop: [Float](repeating: 0.1, count: 5120),
                                     mode: hop < 2 ? "listen" : "speaking")
            for e in events { seen.append("\(e.kind)@\(e.frame)") }
        }
        let closed = engine.frame
        engine.closeTrace()
        engine.reset()
        return Observed(events: seen, rulesCalls: rules.callOrder,
                        modelPrev: model.prevSeen, modelActs: model.acts, frame: closed)
    }

    func testUnsetIsInertAndSetChangesNoDecision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-trace-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("call.jsonl").path
        unsetenv(TurnTrace.envKey)
        let off = driveFixture()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "the flag is unset: the run must not create a file")
        XCTAssertFalse(off.events.isEmpty, "the fixture must emit events")

        setenv(TurnTrace.envKey, path, 1)
        defer { unsetenv(TurnTrace.envKey) }
        let on = driveFixture()

        // The proof: the emitted event sequence and every rules/model call are
        // identical with the log on and off — the log observes, it does not act.
        XCTAssertEqual(on.events, off.events)
        XCTAssertEqual(on.rulesCalls, off.rulesCalls)
        XCTAssertEqual(on.modelPrev, off.modelPrev)
        XCTAssertEqual(on.modelActs, off.modelActs)
        XCTAssertEqual(on.frame, off.frame)
        XCTAssertEqual(on.frame, 12, "3 hops x 4 frames")

        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map { String($0) }
        XCTAssertEqual(lines.count, 13, "one header + one line per frame")

        let header = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(header["rec"] as? String, "session")
        XCTAssertNotNil(header["session"] as? String)
        XCTAssertEqual(header["rate"] as? Int, 16000)
        XCTAssertEqual(header["hop"] as? Int, 5120)
        XCTAssertEqual(header["tier"] as? String, "test")
        XCTAssertNotNil(header["origin_ns"])
        XCTAssertNotNil(header["started_at"])

        var loggedEvents: [String] = []
        var lastT = -1.0
        for (n, line) in lines.dropFirst().enumerated() {
            let rec = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(rec["rec"] as? String, "frame")
            XCTAssertEqual(rec["i"] as? Int, n + 1, "frame indices are the engine's 1-based counter")
            XCTAssertEqual(rec["mode"] as? String, n < 8 ? "listen" : "speaking")
            XCTAssertEqual((rec["out"] as? [Double])?.count, 8)
            // the mock model echoes the state it consumed: [prev, actDb, …]
            XCTAssertEqual(rec["prev"] as? Int, on.modelPrev[n])
            let act = try XCTUnwrap(rec["act_db"] as? Double)
            XCTAssertEqual(act, on.modelActs[n], accuracy: 1e-9)
            XCTAssertEqual(rec["left"] as? Int, 3 - (n % 4))
            let t = try XCTUnwrap(rec["t_ms"] as? Double)
            XCTAssertGreaterThanOrEqual(t, lastT, "t_ms must be monotonic")
            lastT = t
            for e in (rec["events"] as? [[String: Any]]) ?? [] {
                loggedEvents.append("\(e["kind"] as! String)@\(e["frame"] as! Int)")
            }
        }
        // the log's events are exactly the non-FRAME events the caller received
        // (the mock fires on per-hop frame 1 and 3, so every hop contributes)
        XCTAssertEqual(loggedEvents, ["BACKCHANNEL@2", "ENDPOINT@4", "BACKCHANNEL@6",
                                      "ENDPOINT@8", "BACKCHANNEL@10", "ENDPOINT@12"])
        XCTAssertEqual(loggedEvents, on.events.filter { !$0.hasPrefix("FRAME@") })
    }
}
