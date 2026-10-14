import Foundation

/// Runs on-device agent turns on Apple Foundation Models (text and, later,
/// voice). One warm director per agent, recreated when its prompt changes; all
/// work runs off the main thread, since `Director.turn` blocks. All state is
/// confined to `queue`, hence `@unchecked Sendable`.
final class OnDeviceAgentRunner: @unchecked Sendable {
    static let shared = OnDeviceAgentRunner()

    private let queue = DispatchQueue(label: "idfon.on-device-agents")
    private var directors: [String: (instructions: String, director: Director)] = [:]

    private init() {}

    /// Run one plain-text turn for `agent`. Returns the spoken reply, or nil
    /// when AFM is unavailable or the turn failed.
    func reply(agent: OnDeviceAgent, text: String) async -> String? {
        await run(agent: agent) { $0.turn(text) }
    }

    /// Run one turn that points at something: a `TurnInput` (text, artifact
    /// references, attachments) instead of bare text. A reference carries its
    /// selection in the selector, so a local model sees what was pointed at
    /// (`docs/voice-multimodal.md`).
    func reply(agent: OnDeviceAgent, input: [String: Any]) async -> String? {
        await run(agent: agent) { $0.turn(input: input) }
    }

    private func run(agent: OnDeviceAgent, _ body: @escaping (Director) -> [String: Any]?) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let director = self.warmDirector(for: agent) else {
                    continuation.resume(returning: nil)
                    return
                }
                guard let result = body(director) else {
                    continuation.resume(returning: nil)
                    return
                }
                let spoken = Director.spokenText(result)
                continuation.resume(returning: spoken.isEmpty ? nil : spoken)
            }
        }
    }

    /// The agent's director, created on first use and recreated when its prompt
    /// changes. Nil when AFM is unavailable.
    private func warmDirector(for agent: OnDeviceAgent) -> Director? {
        if let cached = directors[agent.id], cached.instructions == agent.instructions {
            return cached.director
        }
        guard let created = Director.createAFM(
            instructions: agent.instructions,
            config: [
                "grant": ["speak"],
                "trace": [
                    "tier": "on-device", "provider": "afm",
                    "model": "apple-foundation-models",
                ],
            ]
        ) else { return nil }
        directors[agent.id] = (agent.instructions, created)
        return created
    }

    /// Drop the cached director for a deleted agent.
    func forget(agentId: String) {
        queue.async { self.directors[agentId] = nil }
    }
}
