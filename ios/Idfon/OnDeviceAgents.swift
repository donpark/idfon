import Foundation

/// A user-created agent that runs locally on Apple Foundation Models.
///
/// Contacts are named prompt configs for the same on-device model: the built-in
/// `AFM 3` plus any the user adds, each with its own `instructions` to fit the
/// role its name suggests. No daemon peer, no network
/// (`docs/voice-agent-modes.md`).
struct OnDeviceAgent: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var instructions: String

    /// The synthetic contact id. `local:` keeps on-device agents out of the
    /// daemon's peer namespace.
    var peerId: String { "local:\(id)" }

    var peer: Peer {
        Peer(id: peerId, name: name, endpointId: nil, aliases: nil, callMode: nil)
    }

    static func id(fromPeerId peerId: String) -> String? {
        guard peerId.hasPrefix("local:") else { return nil }
        return String(peerId.dropFirst("local:".count))
    }
}

/// Local store for on-device agents. Seeded with the built-in `AFM 3` when the
/// device can run Apple Foundation Models.
final class OnDeviceAgents {
    static let shared = OnDeviceAgents()

    static let builtInId = "afm-3"
    static let builtInName = "AFM 3"
    private static let defaultsKey = "idfon.on-device-agents"

    /// Apple Foundation Models need iOS 26. (Apple Intelligence being off is a
    /// runtime condition; a turn then fails and the UI reports it.)
    static var available: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private(set) var agents: [OnDeviceAgent] = []

    private init() {
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([OnDeviceAgent].self, from: data) {
            agents = decoded
        }
        guard Self.available else {
            agents = []
            return
        }
        if !agents.contains(where: { $0.id == Self.builtInId }) {
            agents.insert(
                OnDeviceAgent(id: Self.builtInId, name: Self.builtInName,
                              instructions: DirectorRuntime.onDeviceInstructions),
                at: 0
            )
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(agents) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    func agent(id: String) -> OnDeviceAgent? {
        agents.first { $0.id == id }
    }

    func agent(forPeerId peerId: String) -> OnDeviceAgent? {
        guard let id = OnDeviceAgent.id(fromPeerId: peerId) else { return nil }
        return agent(id: id)
    }

    /// The on-device agents as contacts, in list order.
    var peers: [Peer] { agents.map(\.peer) }

    /// Add a user agent with a custom prompt. Returns it, or nil on an empty
    /// name.
    @discardableResult
    func add(name: String, instructions: String) -> OnDeviceAgent? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let agent = OnDeviceAgent(
            id: UUID().uuidString,
            name: name,
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        agents.append(agent)
        save()
        return agent
    }

    func update(_ agent: OnDeviceAgent) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[index] = agent
        save()
    }

    /// Remove a user agent. The built-in AFM 3 cannot be removed.
    func remove(id: String) {
        guard id != Self.builtInId else { return }
        agents.removeAll { $0.id == id }
        save()
    }
}
