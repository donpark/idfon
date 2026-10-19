import XCTest
@testable import TygerVoice

/// TurnEngine plumbing: the per-frame interleave (prev_state before each step,
/// on_frame right after), the two reset paths, and event surfacing. The rules'
/// own semantics are covered by the Rust fixture suite; the numeric chain by
/// TurnRuntimeTests / MlxRuntimeTests.
final class TurnEngineTests: XCTestCase {
    final class MockModel: TurnModel {
        var resets = 0
        var prevSeen: [Int] = []
        var acts: [Double] = []
        func reset() { resets += 1 }
        func encode(_ window: [Float]) -> [[Float]] {
            // one encoder frame per 1024 window samples, content = the index
            (0..<(window.count / 1024)).map { [Float($0)] }
        }
        func step(hu: [Float], ha: [Float], actDb: Double, prevState: Int) -> [Float] {
            prevSeen.append(prevState)
            acts.append(actDb)
            return [Float(prevState), Float(actDb), 0, 0, 0, 0, 0, 0]
        }
    }

    final class MockRules: TurnRules {
        var callOrder: [String] = []
        var state = 0
        var advanceStatePerFrame = false
        var beginHopResets = false
        var switchModeResult = true
        var frameResetsAt: Set<Int> = []
        var eventsAt: [Int: [[String: Any]]] = [:]
        var finalAudioAt: Int? = nil
        private var frames = 0

        var prevState: Int {
            callOrder.append("prev")
            return state
        }
        func beginHop(user: [Float], agent: [Float], mode: String) -> Bool {
            callOrder.append("begin(\(mode))")
            frames = 0
            return beginHopResets
        }
        func switchMode(_ mode: String) -> Bool {
            callOrder.append("switch(\(mode))")
            return switchModeResult
        }
        func onFrame(outputs: [Float], actDb: Double, left: Int, mode: String) -> FrameOutcome {
            callOrder.append("frame\(frames)")
            var out = FrameOutcome()
            out.events = eventsAt[frames] ?? []
            out.reset = frameResetsAt.contains(frames)
            if frames == finalAudioAt {
                out.finalAudio = [1, 2, 3]
            }
            frames += 1
            if advanceStatePerFrame {
                state += 1
            }
            return out
        }
        func setWords(_ words: String) {}
        func wordsEvent(mode: String) -> [String: Any]? { nil }
        func reset() { callOrder.append("reset") }
    }

    func testInterleaveOrderAndThreading() {
        let model = MockModel()
        let rules = MockRules()
        rules.advanceStatePerFrame = true
        let engine = TurnEngine(model: model, rules: rules)
        // 4096 user samples -> 4 encoder frames -> 4 step frames
        let events = engine.feed(userHop: [Float](repeating: 0, count: 5120),
                                 agentHop: [Float](repeating: 0, count: 5120), mode: "listen")
        XCTAssertTrue(events.isEmpty)
        // the oracle's per-frame order: begin_hop, mode switch, then per frame
        // (prev_state read -> step -> on_frame)
        XCTAssertEqual(rules.callOrder,
                       ["begin(listen)", "switch(listen)", "prev", "frame0", "prev", "frame1",
                        "prev", "frame2", "prev", "frame3", "prev"])
        // each step saw the prev_state as of BEFORE its frame's on_frame
        XCTAssertEqual(model.prevSeen, [0, 1, 2, 3])
        XCTAssertEqual(engine.frame, 4)
    }

    func testResetPaths() {
        let model = MockModel()
        let rules = MockRules()
        rules.beginHopResets = true
        rules.switchModeResult = false
        rules.frameResetsAt = [1]
        let engine = TurnEngine(model: model, rules: rules)
        _ = engine.feed(userHop: [Float](repeating: 0, count: 5120),
                        agentHop: [Float](repeating: 0, count: 5120), mode: "listen")
        XCTAssertEqual(model.resets, 2, "begin_hop reset + the frame's rules reset")
    }

    func testEventsAndFinalAudioSurface() {
        let model = MockModel()
        let rules = MockRules()
        rules.eventsAt = [
            1: [["kind": "FRAME", "state": "LISTEN"]],
            2: [["kind": "ENDPOINT", "turn_s": 1.5]],
        ]
        rules.finalAudioAt = 2
        let engine = TurnEngine(model: model, rules: rules)
        let events = engine.feed(userHop: [Float](repeating: 0, count: 5120),
                                 agentHop: [Float](repeating: 0, count: 5120), mode: "listen")
        XCTAssertEqual(events.map(\.kind), ["FRAME", "ENDPOINT"])
        XCTAssertEqual(events.map(\.frame), [2, 3])
        XCTAssertNil(events[0].finalAudio)
        XCTAssertEqual(events[1].finalAudio ?? [], [1, 2, 3])
    }

    func testModeSwitchRestartsTheRuns() {
        let model = MockModel()
        let rules = MockRules()
        let engine = TurnEngine(model: model, rules: rules)
        _ = engine.feed(userHop: [Float](repeating: 0, count: 5120),
                        agentHop: [Float](repeating: 0, count: 5120), mode: "listen")
        rules.callOrder.removeAll()
        _ = engine.feed(userHop: [Float](repeating: 0, count: 5120),
                        agentHop: [Float](repeating: 0, count: 5120), mode: "listen")
        XCTAssertEqual(rules.callOrder.first, "begin(listen)")
        XCTAssertFalse(rules.callOrder.contains("switch(listen)"), "same mode: no switch")

        rules.callOrder.removeAll()
        _ = engine.feed(userHop: [Float](repeating: 0, count: 5120),
                        agentHop: [Float](repeating: 0, count: 5120), mode: "speaking")
        XCTAssertEqual(rules.callOrder.prefix(2), ["begin(speaking)", "switch(speaking)"])
    }
}
