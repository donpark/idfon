import Foundation

/// The app-owned tool catalog a JSON-render artifact may invoke
/// (`docs/idfon-web-hybrid-plan.md`, P5). Only names registered here can run;
/// anything else is `RenderError.unknown`. This is the same shape an MCP tool
/// registry takes — the idfon operations double as the action set.
enum RenderTools {
    static func make(client: DaemonClient = DaemonClient()) -> RenderToolRegistry {
        let registry = RenderToolRegistry()
        registry.audit = { ActionAudit.shared.record($0) }

        registry.register(RenderTool(
            name: "idfon.status",
            description: "Show daemon readiness and the active identity",
            sensitive: false,
            run: { _ in
                guard let status = try? await client.status() else { return "daemon unavailable" }
                return "ready=\(status.ready) identity=\(status.identityName)"
            }))

        registry.register(RenderTool(
            name: "idfon.peers",
            description: "List contacts",
            sensitive: false,
            run: { _ in
                guard let peers = try? await client.peers() else { return "could not list peers" }
                return peers.isEmpty ? "no contacts" : peers.map(\.name).joined(separator: ", ")
            }))

        registry.register(RenderTool(
            name: "idfon.message.send",
            description: "Send a text message to a peer",
            sensitive: true,
            run: { args in
                guard let peer = args["peer"]?.string, let text = args["text"]?.string else {
                    return "peer and text are required"
                }
                do {
                    try await client.sendText(to: peer, text)
                    return "sent to \(peer)"
                } catch {
                    return "send failed: \(error.localizedDescription)"
                }
            }))

        return registry
    }
}
