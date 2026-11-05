import Foundation

/// One frame's rules result (the Rust `idfon_voice_turn_on_frame` contract).
public struct FrameOutcome {
    /// The rules' event dicts as they crossed the ABI (FRAME included; the
    /// caller filters).
    public var events: [[String: Any]] = []
    /// The turn's audio when a turn ended (the ENDPOINT event is in `events`).
    public var finalAudio: [Float]? = nil
    /// The heads' context must start over after this frame.
    public var reset = false

    public init() {}
}

/// The turn rules behind the engine: the `idfon_voice_turn_*` C ABI in the apps,
/// a scripted mock in tests. One session per conversation.
public protocol TurnRules: AnyObject {
    /// Before a hop's frames (window sliding + turn audio). Returns true when
    /// the heads' context must start over.
    func beginHop(user: [Float], agent: [Float], mode: String) -> Bool
    /// A change between listening and speaking; returns true when it took effect.
    func switchMode(_ mode: String) -> Bool
    /// The state the step consumes for the next frame (0=LISTEN, 1=HOLD,
    /// 2=SPEAK, 3=BACKCHANNEL).
    var prevState: Int { get }
    /// One frame's decision.
    func onFrame(outputs: [Float], actDb: Double, left: Int, mode: String) -> FrameOutcome
    /// The user's words so far, from the ASR thread (feeds PARTIAL events).
    func setWords(_ words: String)
    /// The PARTIAL event when the words changed.
    func wordsEvent(mode: String) -> [String: Any]?
    /// Ask for the heads' context to start over before the next hop.
    func reset()
}

/// A turn event out of the engine: the rules' dict plus the frame it fired on.
public struct TurnEvent {
    public let kind: String
    /// The engine's 80 ms frame counter at the event.
    public let frame: Int
    /// The rules' full event dict.
    public let dict: [String: Any]
    /// Present on the ENDPOINT event of a finished turn: its audio (16 kHz f32).
    public let finalAudio: [Float]?

    public init(kind: String, frame: Int, dict: [String: Any], finalAudio: [Float]? = nil) {
        self.kind = kind
        self.frame = frame
        self.dict = dict
        self.finalAudio = finalAudio
    }
}

/// The live voice loop's turn engine: 320 ms hops in, turn events out. The
/// numeric chain behind it is any ``TurnModel`` (Core ML on iOS, MLX on mac);
/// the rules are any ``TurnRules``. Per frame the order is the oracle's:
/// read prev_state -> step -> rules.on_frame (which threads prev_state).
public final class TurnEngine {
    private let runtime: TurnRuntime
    private let rules: TurnRules
    /// The live-call decision log (#102); nil unless `IDFON_TURN_LOG` is set.
    private let trace: TurnTrace?
    /// The engine's 80 ms frame counter, zeroed by `reset()`.
    public private(set) var frame = 0
    private var lastMode = ""

    public init(model: TurnModel, rules: TurnRules, trace: TurnTrace? = nil) {
        self.runtime = TurnRuntime(model: model)
        self.rules = rules
        self.trace = trace
    }

    /// Flush and close the decision log (the call ended). No-op without a trace.
    public func closeTrace() {
        trace?.close()
    }

    /// The heads' context starts over (mode switches and rules reset points).
    public func reset() {
        runtime.reset()
        rules.reset()
        frame = 0
        lastMode = ""
    }

    /// Feed one hop ("listen" or "speaking"); returns this hop's events —
    /// everything the rules returned (FRAME included; filter `kind` to taste).
    public func feed(userHop: [Float], agentHop: [Float], mode: String) -> [TurnEvent] {
        var pending: [TurnEvent] = []
        // the oracle's hop order: begin_hop (windows + turn audio) then the
        // mode's fresh decision runs, then the frames
        if rules.beginHop(user: userHop, agent: agentHop, mode: mode) {
            runtime.reset()
        }
        if mode != lastMode {
            if rules.switchMode(mode) {
                runtime.reset()
            }
            lastMode = mode
        }
        var pendingFinal: [Float]?
        // the state the next step consumes: the same read that starts the hop,
        // then each frame's return (no extra rules reads — the call order is
        // part of the oracle's contract, see TurnEngineTests)
        var prevConsumed = rules.prevState
        _ = runtime.feed(
            userHop: userHop, agentHop: agentHop, firstState: prevConsumed,
            onFrame: { _, out, actDb, left in
                let outcome = self.rules.onFrame(outputs: out, actDb: actDb, left: left, mode: mode)
                self.frame += 1
                var emitted: [(kind: String, frame: Int)] = []
                for e in outcome.events {
                    let kind = (e["kind"] as? String) ?? "?"
                    pending.append(TurnEvent(kind: kind, frame: self.frame, dict: e, finalAudio: nil))
                    if kind != "FRAME" { emitted.append((kind: kind, frame: self.frame)) }
                }
                if let audio = outcome.finalAudio {
                    pendingFinal = audio
                }
                if outcome.reset {
                    self.runtime.reset()
                }
                self.trace?.frame(index: self.frame, out: out, actDb: actDb, prevState: prevConsumed,
                                  left: left, mode: mode, events: emitted)
                prevConsumed = self.rules.prevState
                return prevConsumed
            })
        self.trace?.endHop()
        if let audio = pendingFinal, let idx = pending.lastIndex(where: { $0.kind == "ENDPOINT" }) {
            let e = pending[idx]
            pending[idx] = TurnEvent(kind: e.kind, frame: e.frame, dict: e.dict, finalAudio: audio)
        }
        return pending
    }

    /// The user's words so far (from the ASR thread).
    public func setWords(_ words: String) {
        rules.setWords(words)
    }

    /// The PARTIAL event for words that changed since the last call.
    public func wordsEvent(mode: String) -> TurnEvent? {
        guard let e = rules.wordsEvent(mode: mode) else { return nil }
        return TurnEvent(kind: (e["kind"] as? String) ?? "PARTIAL", frame: frame, dict: e)
    }
}
