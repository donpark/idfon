import Foundation

/// The on-device conversation director (`crates/idfon-director`): the
/// voice-agent loop over Apple Foundation Models (`docs/voice-agent-loop-contract.md`).
///
/// One director per call. The app prewarms it at call setup (load + warm the
/// AFM session), then runs one turn per caller utterance. A null handle means
/// AFM is unavailable (OS floor / Apple Intelligence off), so the caller falls
/// back to the remote agent.
final class Director {
    private let handle: UnsafeMutableRawPointer

    private init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    /// Create the on-device director with a JSON config:
    /// `grant` (tool names the capability grant permits), `budget`,
    /// `trace` (tier/provider/model), `redaction`.
    static func createAFM(instructions: String, config: [String: Any] = [:]) -> Director? {
        let json = (try? JSONSerialization.data(withJSONObject: config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let pointer = instructions.withCString { text in
            json.withCString { config in idfon_director_new_afm_config(text, config) }
        }
        guard let pointer else { return nil }
        return Director(handle: pointer)
    }

    func prewarm() {
        _ = idfon_director_prewarm(handle)
    }

    /// Run one typed turn. Returns the `TurnResult` object (envelopes + trace
    /// record), or nil on failure.
    func turn(_ text: String) -> [String: Any]? {
        guard let pointer = text.withCString({ idfon_director_turn(handle, $0) }) else { return nil }
        defer { idfon_director_free_string(pointer) }
        return Self.object(String(cString: pointer))
    }

    /// Run one multimodal turn (`TurnInput`: text, references, attachments).
    func turn(input: [String: Any]) -> [String: Any]? {
        let json = (try? JSONSerialization.data(withJSONObject: input))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        guard let pointer = json.withCString({ idfon_director_turn_input(handle, $0) }) else {
            return nil
        }
        defer { idfon_director_free_string(pointer) }
        return Self.object(String(cString: pointer))
    }

    deinit {
        idfon_director_free(handle)
    }

    private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// The `IDFON-*/1` envelopes a turn emitted.
    static func envelopes(_ result: [String: Any]) -> [String] {
        result["envelopes"] as? [String] ?? []
    }

    /// The trace record of a turn.
    static func record(_ result: [String: Any]) -> [String: Any] {
        result["record"] as? [String: Any] ?? [:]
    }

    /// The spoken text of a turn: the first `IDFON-SPEAK/1` envelope.
    static func spokenText(_ result: [String: Any]) -> String {
        let prefix = "IDFON-SPEAK/1\n"
        for envelope in envelopes(result) where envelope.hasPrefix(prefix) {
            let body = String(envelope.dropFirst(prefix.count))
            if let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
               let text = object["text"] as? String, !text.isEmpty {
                return text
            }
        }
        return ""
    }
}

/// The live-call director: one AFM director per call, prewarmed at call setup
/// and run per caller turn. Enabled with `-directorcall`; without it the app
/// keeps the remote agent path. A turn that fails falls back to the remote
/// agent (`VoiceAgentSession.reply`).
final class DirectorRuntime {
    static let shared = DirectorRuntime()

    private var director: Director?
    private(set) var enabled = false

    static let instructions = """
    # Identity
    You are the on-device director for a voice call on this device. Answer the caller briefly.
    # Output rules
    Plain spoken text only. One short sentence.
    # Tools
    speak: say the short spoken reply.
    """

    /// Prepare the director for a call (load + warm the session), off the main
    /// thread. No-op unless `-directorcall` is set, and when AFM is
    /// unavailable. Await it before the first turn so the model is warm.
    func startCall() async {
        guard !enabled, ProcessInfo.processInfo.arguments.contains("-directorcall") else { return }
        let created = await Task.detached(priority: .userInitiated) {
            guard let director = Director.createAFM(instructions: Self.instructions, config: [
                "grant": ["speak", "decide"],
                "trace": ["tier": "on-device", "provider": "afm", "model": "apple-foundation-models"],
            ]) else { return nil }
            let started = Date()
            director.prewarm()
            Automation.mark("director: call prewarm_ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            return director
        }.value
        guard let created else {
            Automation.mark("director: call unavailable (AFM off?)")
            return
        }
        director = created
        enabled = true
    }

    func endCall() {
        director = nil
        enabled = false
    }

    /// Run one caller turn on the director, off the main thread. Returns the
    /// spoken reply, or nil to fall back to the remote agent.
    func turn(_ text: String) async -> String? {
        guard let director else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                guard let result = director.turn(text) else {
                    Automation.mark("director: call FAIL turn")
                    continuation.resume(returning: nil)
                    return
                }
                let spoken = Director.spokenText(result)
                let outcome = Director.record(result)["outcome"] as? [String: Any]
                Automation.mark(
                    "director: call turn_ms=\(Int(Date().timeIntervalSince(started) * 1000)) spoken=\(spoken)"
                )
                Automation.mark("director: call status=\(outcome?["status"] as? String ?? "?")")
                continuation.resume(returning: spoken.isEmpty ? nil : spoken)
            }
        }
    }
}

/// Device automation for the on-device director (`-directortext <text>`): run
/// one real turn and log the prewarm and turn latency. This is the probe for
/// the #41 latency table.
enum DirectorProbe {
    static func run(text: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let instructions = """
            # Identity
            You are the on-device director for a voice call on this device.
            # Output rules
            Plain spoken text only. One short sentence.
            """
            let config: [String: Any] = [
                "grant": ["speak", "decide"],
                "budget": 8,
                "trace": [
                    "tier": "on-device",
                    "provider": "afm",
                    "model": "apple-foundation-models",
                ],
                "redaction": ["policy": "local_only", "local_only": true],
            ]
            guard let director = Director.createAFM(instructions: instructions, config: config) else {
                Automation.mark("director: unavailable (AFM off?)")
                return
            }
            Automation.mark("director: created")

            let warmStart = Date()
            director.prewarm()
            Automation.mark("director: prewarm_ms=\(Self.ms(since: warmStart))")

            let started = Date()
            guard let result = director.turn(text) else {
                Automation.mark("director: FAIL turn")
                return
            }
            Automation.mark("director: turn_ms=\(Self.ms(since: started))")
            for envelope in Director.envelopes(result) {
                let oneLine = envelope.replacingOccurrences(of: "\n", with: " ")
                Automation.mark("director: envelope=\(oneLine)")
            }
            let record = Director.record(result)
            let prompt = record["prompt"] as? [String: Any]
            Automation.mark("director: status=\(record["outcome"] as? [String: Any] ?? [:])")
            Automation.mark("director: prompt_version=\(prompt?["version"] as? String ?? "?")")
            Automation.mark("director: done")
        }
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
