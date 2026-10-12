import Foundation

/// Runs on-device agent turns on Apple Foundation Models (text and, later,
/// voice). One warm director per agent, recreated when its prompt changes; all
/// work runs off the main thread, since `Director.turn` blocks.
final class OnDeviceAgentRunner {
    static let shared = OnDeviceAgentRunner()

    private let queue = DispatchQueue(label: "idfon.on-device-agents")
    private var directors: [String: (instructions: String, director: Director)] = [:]

    private init() {}

    /// Run one turn for `agent`. Returns the spoken reply, or nil when AFM is
    /// unavailable or the turn failed.
    func reply(agent: OnDeviceAgent, text: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let director: Director
                if let cached = self.directors[agent.id], cached.instructions == agent.instructions {
                    director = cached.director
                } else {
                    guard let created = Director.createAFM(
                        instructions: agent.instructions,
                        config: [
                            "grant": ["speak"],
                            "trace": [
                                "tier": "on-device", "provider": "afm",
                                "model": "apple-foundation-models",
                            ],
                        ]
                    ) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.directors[agent.id] = (agent.instructions, created)
                    director = created
                }
                guard let result = director.turn(text) else {
                    continuation.resume(returning: nil)
                    return
                }
                let spoken = Director.spokenText(result)
                continuation.resume(returning: spoken.isEmpty ? nil : spoken)
            }
        }
    }

    /// Drop the cached director for a deleted agent.
    func forget(agentId: String) {
        queue.async { self.directors[agentId] = nil }
    }
}
